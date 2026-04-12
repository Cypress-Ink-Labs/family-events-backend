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
  { slug: "music", keywords: ["music", "sing", "song", "instrument", "drum", "guitar", "violin", "band", "musical", "karaoke", "choir", "concert"] },
  { slug: "outdoor", keywords: ["outdoor", "park", "garden", "hike", "nature", "trail", "playground", "outside", "picnic", "beach", "forest", "camp"] },
  { slug: "storytime", keywords: ["storytime", "story time", "book", "reading", "read aloud", "library", "tales", "narrative", "bedtime"] },
  { slug: "art", keywords: ["art", "craft", "paint", "draw", "sculpture", "pottery", "clay", "creative", "collage", "watercolor", "sketch"] },
  { slug: "science", keywords: ["science", "stem", "experiment", "lab", "chemistry", "biology", "physics", "robot", "coding", "tech", "engineering"] },
  { slug: "sports", keywords: ["sport", "soccer", "basketball", "swim", "gymnastics", "yoga", "dance", "fitness", "run", "martial arts", "tennis"] },
  { slug: "theater", keywords: ["theater", "theatre", "drama", "puppet", "performance", "show", "stage", "act", "improv", "comedy"] },
  { slug: "cooking", keywords: ["cook", "bake", "food", "kitchen", "recipe", "chef", "culinary", "meal", "snack"] },
  { slug: "sensory", keywords: ["sensory", "tactile", "texture", "exploration", "touch", "feel", "messy", "kinetic", "sand", "water play"] },
  { slug: "playgroup", keywords: ["playgroup", "play group", "toddler", "baby", "infant", "mommy and me", "parent and me", "social"] },
  { slug: "free", keywords: ["free", "no cost", "no charge", "complimentary", "at no cost"] },
  { slug: "drop-in", keywords: ["drop-in", "drop in", "walk-in", "no registration", "no booking required"] },
]

function computeTags(title: string, description: string): Array<{ slug: string; confidence: number }> {
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
    const { event_id, title, description } = body

    if (!title) {
      return new Response(
        JSON.stringify({ error: "title is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      )
    }

    const suggestedTags = computeTags(title, description ?? "")
    const topConfidence = suggestedTags[0]?.confidence ?? 0

    if (event_id) {
      const { data: allTags } = await supabase
        .from("tags")
        .select("id, slug")

      if (allTags) {
        const tagMap = new Map(allTags.map((t: { id: string; slug: string }) => [t.slug, t.id]))
        const rows = suggestedTags
          .filter(st => tagMap.has(st.slug))
          .map(st => ({
            event_id,
            tag_id: tagMap.get(st.slug)!,
            ai_confidence: st.confidence,
            source: "ai",
          }))

        if (rows.length > 0) {
          await supabase.from("event_tags").upsert(rows, { onConflict: "event_id,tag_id" })
        }

        await supabase
          .from("events")
          .update({ ai_confidence: topConfidence })
          .eq("id", event_id)
      }
    }

    return new Response(
      JSON.stringify({
        tags: suggestedTags,
        overall_confidence: topConfidence,
        processed: true,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    )
  } catch (err) {
    return new Response(
      JSON.stringify({ error: String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    )
  }
})
