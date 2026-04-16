import "@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "@supabase/supabase-js"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
}

interface TagRule {
  slug: string
  keywords: string[]
}

const TAG_RULES: TagRule[] = [
  {
    slug: "music",
    keywords: [
      "music",
      "sing",
      "song",
      "instrument",
      "drum",
      "guitar",
      "violin",
      "band",
      "musical",
      "karaoke",
      "choir",
      "concert",
    ],
  },
  {
    slug: "outdoor",
    keywords: [
      "outdoor",
      "park",
      "garden",
      "hike",
      "nature",
      "trail",
      "playground",
      "outside",
      "picnic",
      "beach",
      "forest",
      "camp",
    ],
  },
  {
    slug: "storytime",
    keywords: [
      "storytime",
      "story time",
      "book",
      "reading",
      "read aloud",
      "library",
      "tales",
      "narrative",
      "bedtime",
    ],
  },
  {
    slug: "art",
    keywords: [
      "art",
      "craft",
      "paint",
      "draw",
      "sculpture",
      "pottery",
      "clay",
      "creative",
      "collage",
      "watercolor",
      "sketch",
    ],
  },
  {
    slug: "science",
    keywords: [
      "science",
      "stem",
      "experiment",
      "lab",
      "chemistry",
      "biology",
      "physics",
      "robot",
      "coding",
      "tech",
      "engineering",
    ],
  },
  {
    slug: "sports",
    keywords: [
      "sport",
      "soccer",
      "basketball",
      "swim",
      "gymnastics",
      "yoga",
      "dance",
      "fitness",
      "run",
      "martial arts",
      "tennis",
    ],
  },
  {
    slug: "theater",
    keywords: [
      "theater",
      "theatre",
      "drama",
      "puppet",
      "performance",
      "show",
      "stage",
      "act",
      "improv",
      "comedy",
    ],
  },
  {
    slug: "cooking",
    keywords: ["cook", "bake", "food", "kitchen", "recipe", "chef", "culinary", "meal", "snack"],
  },
  {
    slug: "sensory",
    keywords: [
      "sensory",
      "tactile",
      "texture",
      "exploration",
      "touch",
      "feel",
      "messy",
      "kinetic",
      "sand",
      "water play",
    ],
  },
  {
    slug: "playgroup",
    keywords: [
      "playgroup",
      "play group",
      "toddler",
      "baby",
      "infant",
      "mommy and me",
      "parent and me",
      "social",
    ],
  },
  { slug: "free", keywords: ["free", "no cost", "no charge", "complimentary", "at no cost"] },
  {
    slug: "drop-in",
    keywords: ["drop-in", "drop in", "walk-in", "no registration", "no booking required"],
  },
]

interface ClassificationResult {
  tags: Array<{ slug: string; confidence: number }>
  ageMin: number | null
  ageMax: number | null
  price: number | null
  isFree: boolean
  venueName: string | null
  provider: "openai" | "keyword-fallback"
}

function clampConfidence(value: number): number {
  if (Number.isNaN(value)) return 0.5
  return Math.min(1, Math.max(0, value))
}

function computeTags(
  title: string,
  description: string
): Array<{ slug: string; confidence: number }> {
  const text = `${title} ${description}`.toLowerCase()
  const results: Array<{ slug: string; confidence: number }> = []

  for (const rule of TAG_RULES) {
    let hits = 0
    for (const kw of rule.keywords) {
      if (text.includes(kw)) {
        hits++
      }
    }
    if (hits > 0) {
      const confidence = Math.min(0.5 + (hits / rule.keywords.length) * 0.5, 0.98)
      results.push({ slug: rule.slug, confidence: Math.round(confidence * 100) / 100 })
    }
  }

  return results.sort((a, b) => b.confidence - a.confidence)
}

function extractAgeRangeFromText(
  title: string,
  description: string
): { ageMin: number | null; ageMax: number | null } {
  const text = `${title} ${description}`.toLowerCase()

  const rangeMatch = text.match(/(\d{1,2})\s*(?:-|to)\s*(\d{1,2})\s*(?:years?|yrs?|yo|y\/o)/)
  if (rangeMatch) {
    return {
      ageMin: Number(rangeMatch[1]),
      ageMax: Number(rangeMatch[2]),
    }
  }

  const plusMatch = text.match(/(?:ages?\s*)?(\d{1,2})\s*\+/)
  if (plusMatch) {
    return {
      ageMin: Number(plusMatch[1]),
      ageMax: null,
    }
  }

  const underMatch = text.match(/under\s*(\d{1,2})/)
  if (underMatch) {
    return {
      ageMin: null,
      ageMax: Number(underMatch[1]),
    }
  }

  if (text.includes("toddler")) {
    return { ageMin: 1, ageMax: 4 }
  }
  if (text.includes("baby") || text.includes("infant")) {
    return { ageMin: 0, ageMax: 2 }
  }

  return { ageMin: null, ageMax: null }
}

function extractPriceFromText(
  title: string,
  description: string
): { price: number | null; isFree: boolean } {
  const text = `${title} ${description}`.toLowerCase()

  const freePatterns = [/\bfree\b/, /\bno cost\b/, /\bno charge\b/, /\bcomplimentary\b/]
  for (const pattern of freePatterns) {
    if (pattern.test(text)) {
      return { price: null, isFree: true }
    }
  }

  const priceMatch = `${title} ${description}`.match(/\$\s*(\d+(?:\.\d{1,2})?)/)
  if (priceMatch) {
    return { price: Number(priceMatch[1]), isFree: false }
  }

  return { price: null, isFree: false }
}

function extractVenueFromText(title: string, description: string): { venueName: string | null } {
  const text = `${title} ${description}`

  const atMatch = text.match(/\bat\s+(?:the\s+)?([A-Z][A-Za-z\s'&-]{3,40})(?:[,.\n]|$)/)
  if (atMatch) {
    return { venueName: atMatch[1].trim() }
  }

  const locationMatch = text.match(/(?:Location|Venue|Where):\s*([^\n,]{3,60})/i)
  if (locationMatch) {
    return { venueName: locationMatch[1].trim() }
  }

  return { venueName: null }
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
    throw new Error(`OpenAI classification failed (${response.status})`)
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

  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    )

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
    } | null = null

    if (event_id) {
      const { data: eventRow } = await supabase
        .from("events")
        .select("title, description, price, is_free, venue_name")
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
      } catch (_) {
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
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
