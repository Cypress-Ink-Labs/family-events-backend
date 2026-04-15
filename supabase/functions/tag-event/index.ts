import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2"

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
            "You classify family events. Respond with JSON only: { tags: [{ slug: string, confidence: number }], age_min: number|null, age_max: number|null }",
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

  return { tags, ageMin, ageMax }
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

    if (event_id && (!title || !description)) {
      const { data: eventRow } = await supabase
        .from("events")
        .select("title, description")
        .eq("id", event_id)
        .maybeSingle()

      if (eventRow) {
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
          provider: "openai",
        }
      } catch (_) {
        const fallbackAge = extractAgeRangeFromText(title, description)
        classification = {
          tags: computeTags(title, description ?? ""),
          ageMin: fallbackAge.ageMin,
          ageMax: fallbackAge.ageMax,
          provider: "keyword-fallback",
        }
      }
    } else {
      const fallbackAge = extractAgeRangeFromText(title, description)
      classification = {
        tags: computeTags(title, description ?? ""),
        ageMin: fallbackAge.ageMin,
        ageMax: fallbackAge.ageMax,
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

      await supabase
        .from("events")
        .update({
          ai_confidence: topConfidence,
          age_min: classification.ageMin,
          age_max: classification.ageMax,
        })
        .eq("id", event_id)
    }

    return new Response(
      JSON.stringify({
        tags: normalizedTags,
        provider: classification.provider,
        age_min: classification.ageMin,
        age_max: classification.ageMax,
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
