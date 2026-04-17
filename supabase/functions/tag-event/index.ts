import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { requireServiceRole } from "../_shared/auth.ts"
import {
  clampConfidence,
  computeTags,
  extractAgeRangeFromText,
  extractPriceFromText,
  extractVenueFromText,
} from "../_shared/classification.ts"
import { buildGeocodeQuery, geocodeViaNominatim } from "../_shared/geocode.ts"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

type TagProvider = "openai" | "keyword-fallback"

interface ClassificationResult {
  tags: Array<{ slug: string; confidence: number }>
  ageMin: number | null
  ageMax: number | null
  price: number | null
  isFree: boolean
  venueName: string | null
  provider: TagProvider
}

async function classifyWithOpenAI(
  apiKey: string,
  model: string,
  title: string,
  description: string,
  availableTags: Array<{ slug: string; name: string }>
): Promise<{
  tags: Array<{ slug: string; confidence: number }>
  ageMin: number | null
  ageMax: number | null
  price: number | null
  isFree: boolean
  venueName: string | null
}> {
  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      temperature: 0.1,
      response_format: { type: "json_object" },
      messages: [
        {
          role: "system",
          content:
            'You classify and enrich family event data. Respond with JSON only: { "tags": [{ "slug": string, "confidence": number }], "age_min": number|null, "age_max": number|null, "price": number|null, "is_free": boolean, "venue_name": string|null }',
        },
        {
          role: "user",
          content: JSON.stringify({
            title,
            description,
            available_tags: availableTags,
            instructions: [
              "Choose up to 6 relevant tags from available_tags only.",
              "confidence must be between 0 and 1.",
              "Extract age_min and age_max if present in text. Use null when unknown.",
              'Extract price if mentioned (e.g. "$15"). If "free"/"no cost"/"complimentary", set is_free=true and price=null. If a dollar amount is found, set is_free=false and price to the number. If unknown, set is_free=false and price=null.',
              'Extract venue_name if mentioned (e.g. "at Central Library", "Location: City Park"). Use null when unknown.',
            ],
          }),
        },
      ],
    }),
  })

  if (!response.ok) {
    const errorBody = await response.text().catch(() => "")
    throw new Error(`OpenAI classification failed (${response.status}): ${errorBody.slice(0, 200)}`)
  }

  const completion = await response.json()
  const rawContent = completion?.choices?.[0]?.message?.content
  if (!rawContent) {
    throw new Error("OpenAI returned an empty response")
  }

  const parsed = JSON.parse(rawContent)
  const tags = Array.isArray(parsed?.tags)
    ? parsed.tags
        .map((tag: { slug?: string; confidence?: number }) => ({
          slug: String(tag?.slug ?? ""),
          confidence: clampConfidence(Number(tag?.confidence ?? 0.5)),
        }))
        .filter((tag: { slug: string; confidence: number }) => tag.slug)
    : []

  const ageMin = typeof parsed?.age_min === "number" ? parsed.age_min : null
  const ageMax = typeof parsed?.age_max === "number" ? parsed.age_max : null
  const price = typeof parsed?.price === "number" ? parsed.price : null
  const isFree = parsed?.is_free === true
  const venueName = typeof parsed?.venue_name === "string" ? parsed.venue_name : null

  return { tags, ageMin, ageMax, price, isFree, venueName }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

  // Auth: service role only. This function is internal (called from scrape-source).
  const auth = requireServiceRole(req, serviceRoleKey)
  if (!auth.ok) {
    return new Response(JSON.stringify({ error: auth.message }), {
      status: auth.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }

  try {
    const supabase = createClient(Deno.env.get("SUPABASE_URL") ?? "", serviceRoleKey)

    const body = await req.json()
    const { event_id } = body
    let title = typeof body?.title === "string" ? body.title.trim() : ""
    let description = typeof body?.description === "string" ? body.description : ""

    let currentEvent: {
      title: string
      description: string | null
      price: number | null
      is_free: boolean
      venue_name: string | null
      address: string | null
      latitude: number | null
      longitude: number | null
      city_id: string | null
    } | null = null

    if (event_id) {
      const { data: eventRow } = await supabase
        .from("events")
        .select("title, description, price, is_free, venue_name, address, latitude, longitude, city_id")
        .eq("id", event_id)
        .maybeSingle()

      if (eventRow) {
        currentEvent = eventRow
        title = title || eventRow.title
        description = description || eventRow.description || ""
      }
    }

    if (!title) {
      return new Response(JSON.stringify({ error: "title is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      })
    }

    const { data: availableTags, error: tagsError } = await supabase
      .from("tags")
      .select("id, slug, name")

    if (tagsError) {
      throw tagsError
    }

    const openAiApiKey = Deno.env.get("OPENAI_API_KEY")
    const openAiModel = Deno.env.get("OPENAI_MODEL") ?? "gpt-4o-mini"

    let classification: ClassificationResult

    if (openAiApiKey) {
      try {
        const aiResult = await classifyWithOpenAI(
          openAiApiKey,
          openAiModel,
          title,
          description,
          availableTags ?? []
        )
        classification = {
          tags: aiResult.tags,
          ageMin: aiResult.ageMin,
          ageMax: aiResult.ageMax,
          price: aiResult.price,
          isFree: aiResult.isFree,
          venueName: aiResult.venueName,
          provider: "openai",
        }
      } catch (openAiError) {
        // Surface the failure — admin needs to know if OpenAI is down/unauthorized,
        // otherwise every event silently drops to lower-quality keyword tagging.
        console.error("OpenAI classification failed, falling back to keyword matching", {
          event_id: event_id ?? null,
          error: openAiError instanceof Error ? openAiError.message : String(openAiError),
        })
        const fallbackAge = extractAgeRangeFromText(title, description)
        const fallbackPrice = extractPriceFromText(title, description)
        const fallbackVenue = extractVenueFromText(title, description)
        classification = {
          tags: computeTags(title, description ?? ""),
          ageMin: fallbackAge.ageMin,
          ageMax: fallbackAge.ageMax,
          price: fallbackPrice.price,
          isFree: fallbackPrice.isFree,
          venueName: fallbackVenue.venueName,
          provider: "keyword-fallback",
        }
      }
    } else {
      const fallbackAge = extractAgeRangeFromText(title, description)
      const fallbackPrice = extractPriceFromText(title, description)
      const fallbackVenue = extractVenueFromText(title, description)
      classification = {
        tags: computeTags(title, description ?? ""),
        ageMin: fallbackAge.ageMin,
        ageMax: fallbackAge.ageMax,
        price: fallbackPrice.price,
        isFree: fallbackPrice.isFree,
        venueName: fallbackVenue.venueName,
        provider: "keyword-fallback",
      }
    }

    const normalizedTags = classification.tags
      .filter((tag) => (availableTags ?? []).some((candidate) => candidate.slug === tag.slug))
      .sort((a, b) => b.confidence - a.confidence)
      .slice(0, 6)
    const topConfidence =
      normalizedTags.length > 0
        ? normalizedTags.reduce((total, tag) => total + tag.confidence, 0) / normalizedTags.length
        : 0

    if (event_id) {
      const tagMap = new Map(
        (availableTags ?? []).map((tag: { id: string; slug: string }) => [tag.slug, tag.id])
      )

      const { data: manualOverrides } = await supabase
        .from("event_tags")
        .select("tag_id")
        .eq("event_id", event_id)
        .eq("is_manual_override", true)

      const manualOverrideTagIds = new Set((manualOverrides ?? []).map((row) => row.tag_id))

      await supabase
        .from("event_tags")
        .delete()
        .eq("event_id", event_id)
        .eq("is_manual_override", false)

      const rows = normalizedTags
        .filter((tag) => {
          const tagId = tagMap.get(tag.slug)
          return tagId && !manualOverrideTagIds.has(tagId)
        })
        .map((tag) => ({
          event_id,
          tag_id: tagMap.get(tag.slug)!,
          confidence: tag.confidence,
          is_manual_override: false,
        }))

      if (rows.length > 0) {
        await supabase.from("event_tags").upsert(rows, { onConflict: "event_id,tag_id" })
      }

      const updatePayload: Record<string, unknown> = {
        ai_confidence: topConfidence,
        ai_tag_provider: classification.provider,
        age_min: classification.ageMin,
        age_max: classification.ageMax,
      }
      // Only fill gaps — don't overwrite scraper-extracted values
      if (classification.price !== null && currentEvent?.price == null) {
        updatePayload.price = classification.price
      }
      if (classification.isFree && !currentEvent?.is_free) {
        updatePayload.is_free = classification.isFree
      }
      if (classification.venueName && !currentEvent?.venue_name) {
        updatePayload.venue_name = classification.venueName
      }

      // Geocode if event has no coords yet. Prefer address → venue → city fallback.
      const needsGeocode =
        currentEvent?.latitude == null || currentEvent?.longitude == null
      if (needsGeocode) {
        const resolvedVenue =
          currentEvent?.venue_name ?? (classification.venueName as string | null)
        const resolvedAddress = currentEvent?.address ?? null

        let city: { name: string; state: string | null; latitude: number | null; longitude: number | null } | null = null
        if (currentEvent?.city_id) {
          const { data: cityRow } = await supabase
            .from("cities")
            .select("name, state, latitude, longitude")
            .eq("id", currentEvent.city_id)
            .maybeSingle()
          city = cityRow as typeof city
        }

        const query = buildGeocodeQuery({
          address: resolvedAddress,
          venueName: resolvedVenue,
          cityName: city?.name ?? null,
          cityState: city?.state ?? null,
        })

        let geocoded: { latitude: number; longitude: number } | null = null
        if (query) {
          const hit = await geocodeViaNominatim(query)
          if (hit) geocoded = { latitude: hit.latitude, longitude: hit.longitude }
        }

        // Fallback: use city center so the pin still appears on the map.
        if (!geocoded && city?.latitude != null && city?.longitude != null) {
          geocoded = { latitude: city.latitude, longitude: city.longitude }
        }

        if (geocoded) {
          updatePayload.latitude = geocoded.latitude
          updatePayload.longitude = geocoded.longitude
        }
      }

      await supabase.from("events").update(updatePayload).eq("id", event_id)
    }

    return new Response(
      JSON.stringify({
        tags: normalizedTags,
        provider: classification.provider,
        age_min: classification.ageMin,
        age_max: classification.ageMax,
        price: classification.price,
        is_free: classification.isFree,
        venue_name: classification.venueName,
        overall_confidence: topConfidence,
        processed: true,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    )
  } catch (err) {
    console.error("tag-event handler failed", {
      error: err instanceof Error ? err.message : String(err),
    })
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
