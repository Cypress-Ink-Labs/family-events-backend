import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"
import { requireServiceRole } from "../_shared/auth.ts"
import { captureEdgeException } from "../_shared/sentry.ts"
import { errorContext, logEdgeEvent } from "../_shared/logger.ts"
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
type ClassificationStatus = "success" | "fallback" | "error"
type TriggerType = "import" | "reclassify" | "manual-review"

interface ClassificationTag {
  slug: string
  confidence: number
  reason: string | null
  matchedKeywords?: string[]
}

interface ClassificationResult {
  tags: ClassificationTag[]
  ageMin: number | null
  ageMax: number | null
  price: number | null
  isFree: boolean
  venueName: string | null
  provider: TagProvider
  reasoningSummary: string | null
  status: ClassificationStatus
  fallbackReason: string | null
  model: string | null
}

function buildKeywordFallbackSummary(openAiConfigured: boolean): string {
  return openAiConfigured
    ? "Keyword fallback classified this event because OpenAI was unavailable. Matching keywords were used to assign tags."
    : "Keyword fallback classified this event because no OpenAI API key was configured. Matching keywords were used to assign tags."
}

async function classifyWithOpenAI(
  apiKey: string,
  model: string,
  title: string,
  description: string,
  availableTags: Array<{ slug: string; name: string }>
): Promise<{
  tags: ClassificationTag[]
  ageMin: number | null
  ageMax: number | null
  price: number | null
  isFree: boolean
  venueName: string | null
  reasoningSummary: string | null
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
            'You classify and enrich family event data. Respond with JSON only: { "tags": [{ "slug": string, "confidence": number, "reason": string|null }], "age_min": number|null, "age_max": number|null, "price": number|null, "is_free": boolean, "venue_name": string|null, "reasoning_summary": string|null }',
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
              "Provide a brief reasoning_summary explaining how the event was classified for admin review.",
              "Each tag may include a short reason string quoting or paraphrasing the evidence.",
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
        .map((tag: { slug?: string; confidence?: number; reason?: string | null }) => ({
          slug: String(tag?.slug ?? ""),
          confidence: clampConfidence(Number(tag?.confidence ?? 0.5)),
          reason: typeof tag?.reason === "string" ? tag.reason : null,
        }))
        .filter((tag: { slug: string; confidence: number; reason: string | null }) => tag.slug)
    : []

  const ageMin = typeof parsed?.age_min === "number" ? parsed.age_min : null
  const ageMax = typeof parsed?.age_max === "number" ? parsed.age_max : null
  const price = typeof parsed?.price === "number" ? parsed.price : null
  const isFree = parsed?.is_free === true
  const venueName = typeof parsed?.venue_name === "string" ? parsed.venue_name : null
  const reasoningSummary =
    typeof parsed?.reasoning_summary === "string" ? parsed.reasoning_summary : null

  return { tags, ageMin, ageMax, price, isFree, venueName, reasoningSummary }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders })
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""

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
    const eventId = typeof body?.event_id === "string" ? body.event_id : null
    const sourceRunId = typeof body?.source_run_id === "string" ? body.source_run_id : null
    const triggerType: TriggerType =
      body?.trigger_type === "reclassify" || body?.trigger_type === "manual-review"
        ? body.trigger_type
        : "import"
    const traceStartedAt = Date.now()
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

    if (eventId) {
      const { data: eventRow, error: eventError } = await supabase
        .from("events")
        .select("title, description, price, is_free, venue_name, address, latitude, longitude, city_id")
        .eq("id", eventId)
        .maybeSingle()

      if (eventError) {
        throw eventError
      }

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
          reasoningSummary: aiResult.reasoningSummary,
          status: "success",
          fallbackReason: null,
          model: openAiModel,
        }
      } catch (openAiError) {
        await captureEdgeException(
          openAiError,
          errorContext(openAiError, {
            function: "tag-event",
            event_id: eventId,
            source_run_id: sourceRunId,
            trigger_type: triggerType,
            provider: "openai",
            status: "fallback",
          })
        )
        logEdgeEvent(
          "warn",
          "OpenAI classification failed, falling back to keyword matching",
          errorContext(openAiError, {
            function: "tag-event",
            event_id: eventId,
            source_run_id: sourceRunId,
            trigger_type: triggerType,
            provider: "openai",
            status: "fallback",
          })
        )

        const fallbackAge = extractAgeRangeFromText(title, description)
        const fallbackPrice = extractPriceFromText(title, description)
        const fallbackVenue = extractVenueFromText(title, description)
        const fallbackTags = computeTags(title, description)

        classification = {
          tags: fallbackTags,
          ageMin: fallbackAge.ageMin,
          ageMax: fallbackAge.ageMax,
          price: fallbackPrice.price,
          isFree: fallbackPrice.isFree,
          venueName: fallbackVenue.venueName,
          provider: "keyword-fallback",
          reasoningSummary: buildKeywordFallbackSummary(true),
          status: "fallback",
          fallbackReason: openAiError instanceof Error ? openAiError.message : String(openAiError),
          model: openAiModel,
        }
      }
    } else {
      const fallbackAge = extractAgeRangeFromText(title, description)
      const fallbackPrice = extractPriceFromText(title, description)
      const fallbackVenue = extractVenueFromText(title, description)
      const fallbackTags = computeTags(title, description)

      classification = {
        tags: fallbackTags,
        ageMin: fallbackAge.ageMin,
        ageMax: fallbackAge.ageMax,
        price: fallbackPrice.price,
        isFree: fallbackPrice.isFree,
        venueName: fallbackVenue.venueName,
        provider: "keyword-fallback",
        reasoningSummary: buildKeywordFallbackSummary(false),
        status: "fallback",
        fallbackReason: "OPENAI_API_KEY is not configured",
        model: openAiModel,
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

    if (eventId) {
      const { error: traceInsertError } = await supabase.from("event_ai_traces").insert({
        event_id: eventId,
        source_run_id: sourceRunId,
        trigger_type: triggerType,
        provider: classification.provider,
        model: classification.model,
        status: classification.status,
        input_title: title,
        input_description: description || null,
        available_tag_slugs: (availableTags ?? []).map((tag) => tag.slug),
        predicted_tags: normalizedTags.map((tag) => ({
          slug: tag.slug,
          confidence: tag.confidence,
          reason: tag.reason,
          matched_keywords: tag.matchedKeywords ?? [],
        })),
        predicted_fields: {
          age_min: classification.ageMin,
          age_max: classification.ageMax,
          price: classification.price,
          is_free: classification.isFree,
          venue_name: classification.venueName,
        },
        reasoning_summary: classification.reasoningSummary,
        fallback_reason: classification.fallbackReason,
        processing_ms: Date.now() - traceStartedAt,
      })

      if (traceInsertError) {
        await captureEdgeException(
          traceInsertError,
          errorContext(traceInsertError, {
            function: "tag-event",
            event_id: eventId,
            source_run_id: sourceRunId,
            trigger_type: triggerType,
          })
        )
        logEdgeEvent(
          "error",
          "Failed to persist AI trace",
          errorContext(traceInsertError, {
            function: "tag-event",
            event_id: eventId,
            source_run_id: sourceRunId,
            trigger_type: triggerType,
          })
        )
      }

      const tagMap = new Map((availableTags ?? []).map((tag) => [tag.slug, tag.id]))

      const { data: manualOverrides, error: manualOverridesError } = await supabase
        .from("event_tags")
        .select("tag_id")
        .eq("event_id", eventId)
        .eq("is_manual_override", true)

      if (manualOverridesError) {
        throw manualOverridesError
      }

      const manualOverrideTagIds = new Set((manualOverrides ?? []).map((row) => row.tag_id))

      const { error: deleteError } = await supabase
        .from("event_tags")
        .delete()
        .eq("event_id", eventId)
        .eq("is_manual_override", false)

      if (deleteError) {
        throw deleteError
      }

      const rows = normalizedTags
        .filter((tag) => {
          const tagId = tagMap.get(tag.slug)
          return tagId && !manualOverrideTagIds.has(tagId)
        })
        .map((tag) => ({
          event_id: eventId,
          tag_id: tagMap.get(tag.slug)!,
          confidence: tag.confidence,
          is_manual_override: false,
        }))

      if (rows.length > 0) {
        const { error: upsertError } = await supabase
          .from("event_tags")
          .upsert(rows, { onConflict: "event_id,tag_id" })

        if (upsertError) {
          throw upsertError
        }
      }

      const updatePayload: Record<string, unknown> = {
        ai_confidence: topConfidence,
        ai_tag_provider: classification.provider,
        age_min: classification.ageMin,
        age_max: classification.ageMax,
      }

      if (classification.price !== null && currentEvent?.price == null) {
        updatePayload.price = classification.price
      }
      if (classification.isFree && !currentEvent?.is_free) {
        updatePayload.is_free = classification.isFree
      }
      if (classification.venueName && !currentEvent?.venue_name) {
        updatePayload.venue_name = classification.venueName
      }

      const needsGeocode = currentEvent?.latitude == null || currentEvent?.longitude == null
      if (needsGeocode) {
        const resolvedVenue = currentEvent?.venue_name ?? classification.venueName
        const resolvedAddress = currentEvent?.address ?? null

        type CityLookup = {
          name: string
          state: string | null
          latitude: number | null
          longitude: number | null
        }

        let city: CityLookup | null = null
        if (currentEvent?.city_id) {
          const { data: cityRow, error: cityError } = await supabase
            .from("cities")
            .select("name, state, latitude, longitude")
            .eq("id", currentEvent.city_id)
            .maybeSingle()

          if (cityError) {
            throw cityError
          }

          city = cityRow as CityLookup | null
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
          if (hit) {
            geocoded = { latitude: hit.latitude, longitude: hit.longitude }
          }
        }

        if (!geocoded && city?.latitude != null && city?.longitude != null) {
          geocoded = { latitude: city.latitude, longitude: city.longitude }
        }

        if (geocoded) {
          updatePayload.latitude = geocoded.latitude
          updatePayload.longitude = geocoded.longitude
        }
      }

      const { error: eventUpdateError } = await supabase
        .from("events")
        .update(updatePayload)
        .eq("id", eventId)

      if (eventUpdateError) {
        throw eventUpdateError
      }
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
        reasoning_summary: classification.reasoningSummary,
        fallback_reason: classification.fallbackReason,
        status: classification.status,
        model: classification.model,
        overall_confidence: topConfidence,
        processed: true,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    )
  } catch (err) {
    await captureEdgeException(
      err,
      errorContext(err, {
        function: "tag-event",
        event_id: null,
      })
    )
    logEdgeEvent(
      "error",
      "tag-event handler failed",
      errorContext(err, {
        function: "tag-event",
        event_id: null,
      })
    )

    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
