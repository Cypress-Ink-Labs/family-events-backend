/**
 * Memory context retrieval for adaptive pipeline.
 *
 * Fetches similar events and their associated tags, admin corrections,
 * and review outcomes to build few-shot context for LLM prompts.
 */

import type { SupabaseClient } from "@supabase/supabase-js"
import { logEdgeEvent } from "./logger.ts"

// ── Types ────────────────────────────────────────────────────────────────────

export interface SimilarEventTag {
  slug: string
  name: string
  source: "ai" | "admin"
  confidence: number
}

export interface SimilarEventTagContext {
  eventId: string
  title: string
  cosineDistance: number
  tags: SimilarEventTag[]
  adminCorrected: boolean
  adminReason: string | null
}

export interface SimilarEventReviewContext {
  eventId: string
  title: string
  cosineDistance: number
  status: string
  llmReviewDecision: string | null
  adminOverridden: boolean
  adminDecision: string | null
  adminReason: string | null
}

export interface ReviewConfidenceAdjustment {
  delta: number
  reason: string
  approvedCount: number
  rejectedCount: number
  totalSimilar: number
}

// ── Feature flag check ───────────────────────────────────────────────────────

export async function isMemoryFeatureEnabled(
  supabase: SupabaseClient,
  feature: "tag-memory" | "review-memory" | "source-auto-reject"
): Promise<boolean> {
  try {
    const { data, error } = await supabase
      .from("ai_feature_config")
      .select("enabled")
      .eq("feature", feature)
      .maybeSingle()
    if (error || !data) return false
    return (data as { enabled: boolean }).enabled === true
  } catch {
    return false
  }
}

// ── Tagging memory context ───────────────────────────────────────────────────

interface SimilarEventRow {
  event_id: string
  title: string
  cosine_distance: number
  source_id: string | null
  city_id: string | null
  status: string
}

interface EventTagRow {
  event_id: string
  tag_id: string
  confidence: number
  is_manual_override: boolean
  tags: { slug: string; name: string } | null
}

interface AdminDecisionRow {
  event_id: string
  decision_type: string
  new_tags: unknown
  reason: string | null
  created_at: string
}

interface ReviewEventRow {
  id: string
  status: string
  llm_review_decision: string | null
}

interface ReviewAdminDecisionRow {
  event_id: string
  decision_type: string
  new_status: string
  reason: string | null
  created_at: string
}

export async function fetchSimilarEventTagContext(
  supabase: SupabaseClient,
  embedding: number[],
  excludeEventId: string | null,
  cityId: string | null,
  limit = 5
): Promise<SimilarEventTagContext[]> {
  const vectorStr = `[${embedding.join(",")}]`

  const { data: similar, error: simError } = await supabase.rpc("find_similar_events", {
    p_embedding: vectorStr,
    p_limit: limit,
    p_threshold: 0.3,
    p_exclude_event_id: excludeEventId,
    p_city_id: cityId,
  })

  if (simError) throw simError
  const similarRows = (similar ?? []) as SimilarEventRow[]
  if (similarRows.length === 0) return []

  const eventIds = [...new Set(similarRows.map((row) => row.event_id))]
  const { data: tagRows, error: tagError } = await supabase
    .from("event_tags")
    .select("event_id, tag_id, confidence, is_manual_override, tags(slug, name)")
    .in("event_id", eventIds)

  if (tagError) {
    logEdgeEvent("warn", "memory-context: failed to bulk fetch tags for similar events", {
      error: tagError.message,
    })
    return []
  }

  const { data: decisionRows, error: decisionError } = await supabase
    .from("admin_event_decisions")
    .select("event_id, decision_type, new_tags, reason, created_at")
    .in("event_id", eventIds)
    .in("decision_type", ["tag_edit", "status_and_tags"])
    .order("created_at", { ascending: false })

  if (decisionError) {
    logEdgeEvent("warn", "memory-context: failed to bulk fetch tag decisions for similar events", {
      error: decisionError.message,
    })
    return []
  }

  const tagsByEvent = new Map<string, EventTagRow[]>()
  for (const tagRow of (tagRows ?? []) as unknown as EventTagRow[]) {
    const tags = tagsByEvent.get(tagRow.event_id) ?? []
    tags.push(tagRow)
    tagsByEvent.set(tagRow.event_id, tags)
  }

  const decisionsByEvent = new Map<string, AdminDecisionRow>()
  for (const decisionRow of (decisionRows ?? []) as unknown as AdminDecisionRow[]) {
    if (!decisionsByEvent.has(decisionRow.event_id)) {
      decisionsByEvent.set(decisionRow.event_id, decisionRow)
    }
  }

  return similarRows.map((row) => {
    const tags: SimilarEventTag[] = (tagsByEvent.get(row.event_id) ?? [])
      .filter((tag) => tag.tags)
      .map((tag) => ({
        slug: tag.tags!.slug,
        name: tag.tags!.name,
        source: tag.is_manual_override ? ("admin" as const) : ("ai" as const),
        confidence: tag.confidence,
      }))
      .sort((a, b) => {
        if (a.source !== b.source) return a.source === "admin" ? -1 : 1
        return b.confidence - a.confidence
      })
    const latestDecision = decisionsByEvent.get(row.event_id) ?? null

    return {
      eventId: row.event_id,
      title: row.title.slice(0, 100),
      cosineDistance: row.cosine_distance,
      tags,
      adminCorrected: latestDecision !== null || tags.some((tag) => tag.source === "admin"),
      adminReason: latestDecision?.reason ?? null,
    }
  })
}

// ── Review memory context ────────────────────────────────────────────────────

export async function fetchSimilarReviewContext(
  supabase: SupabaseClient,
  embedding: number[],
  excludeEventId: string | null,
  cityId: string | null,
  limit = 5
): Promise<{
  contexts: SimilarEventReviewContext[]
  confidenceAdjustment: ReviewConfidenceAdjustment
}> {
  const vectorStr = `[${embedding.join(",")}]`

  const { data: similar, error: simError } = await supabase.rpc("find_similar_events", {
    p_embedding: vectorStr,
    p_limit: limit,
    p_threshold: 0.3,
    p_exclude_event_id: excludeEventId,
    p_city_id: cityId,
  })

  if (simError) throw simError

  const similarRows = (similar ?? []) as SimilarEventRow[]
  if (similarRows.length === 0) {
    return {
      contexts: [],
      confidenceAdjustment: {
        delta: 0,
        reason: "no similar events found",
        approvedCount: 0,
        rejectedCount: 0,
        totalSimilar: 0,
      },
    }
  }

  const eventIds = [...new Set(similarRows.map((row) => row.event_id))]
  const { data: eventRows, error: eventError } = await supabase
    .from("events")
    .select("id, status, llm_review_decision")
    .in("id", eventIds)

  if (eventError) {
    logEdgeEvent("warn", "memory-context: failed to bulk fetch review events", {
      error: eventError.message,
    })
    return {
      contexts: [],
      confidenceAdjustment: {
        delta: 0,
        reason: "no similar events found",
        approvedCount: 0,
        rejectedCount: 0,
        totalSimilar: 0,
      },
    }
  }

  const { data: decisionRows, error: decisionError } = await supabase
    .from("admin_event_decisions")
    .select("event_id, decision_type, new_status, reason, created_at")
    .eq("decision_type", "status_change")
    .in("event_id", eventIds)
    .order("created_at", { ascending: false })

  if (decisionError) {
    logEdgeEvent("warn", "memory-context: failed to bulk fetch review decisions", {
      error: decisionError.message,
    })
    return {
      contexts: [],
      confidenceAdjustment: {
        delta: 0,
        reason: "no similar events found",
        approvedCount: 0,
        rejectedCount: 0,
        totalSimilar: 0,
      },
    }
  }

  const eventsById = new Map<string, ReviewEventRow>()
  for (const eventRow of (eventRows ?? []) as unknown as ReviewEventRow[]) {
    eventsById.set(eventRow.id, eventRow)
  }

  const decisionsByEvent = new Map<string, ReviewAdminDecisionRow>()
  for (const decisionRow of (decisionRows ?? []) as unknown as ReviewAdminDecisionRow[]) {
    if (!decisionsByEvent.has(decisionRow.event_id)) {
      decisionsByEvent.set(decisionRow.event_id, decisionRow)
    }
  }

  const contexts: SimilarEventReviewContext[] = []
  let approvedCount = 0
  let rejectedCount = 0

  for (const row of similarRows) {
    const eventRow = eventsById.get(row.event_id)
    if (!eventRow) continue

    const latestAdminDecision = decisionsByEvent.get(row.event_id) ?? null
    if (eventRow.status === "published") approvedCount++
    if (eventRow.status === "rejected") rejectedCount++

    contexts.push({
      eventId: row.event_id,
      title: row.title.slice(0, 100),
      cosineDistance: row.cosine_distance,
      status: eventRow.status,
      llmReviewDecision: eventRow.llm_review_decision,
      adminOverridden: latestAdminDecision !== null,
      adminDecision: latestAdminDecision?.new_status ?? null,
      adminReason: latestAdminDecision?.reason ?? null,
    })
  }

  const totalSimilar = contexts.length
  let delta = 0
  let reason = "mixed outcomes among similar events"

  if (totalSimilar > 0) {
    const approvedRate = approvedCount / totalSimilar
    const rejectedRate = rejectedCount / totalSimilar

    if (approvedRate >= 0.8) {
      delta = 0.1
      reason = `${approvedCount}/${totalSimilar} similar events were approved`
    } else if (rejectedRate >= 0.8) {
      delta = -0.1
      reason = `${rejectedCount}/${totalSimilar} similar events were rejected`
    }
  }

  return {
    contexts,
    confidenceAdjustment: { delta, reason, approvedCount, rejectedCount, totalSimilar },
  }
}

// ── Prompt formatting helpers ────────────────────────────────────────────────

export function formatTagMemoryPrompt(contexts: SimilarEventTagContext[]): string {
  if (contexts.length === 0) return ""

  const lines = ["", "MEMORY CONTEXT — similar events previously processed:"]

  for (const ctx of contexts) {
    const tagList = ctx.tags
      .map((t) => {
        const suffix = t.source === "admin" ? " (admin-corrected)" : ""
        return `${t.slug}${suffix}`
      })
      .join(", ")

    const correctionNote = ctx.adminCorrected ? " [ADMIN CORRECTED]" : ""
    lines.push(`- "${ctx.title}" → tags: [${tagList}]${correctionNote}`)
    if (ctx.adminReason) {
      lines.push(`  Admin reason: ${ctx.adminReason}`)
    }
  }

  lines.push("")
  lines.push(
    "Use these examples as reference when classifying the current event. Admin-corrected tags are higher-quality signals."
  )

  return lines.join("\n")
}

export function formatReviewMemoryPrompt(contexts: SimilarEventReviewContext[]): string {
  if (contexts.length === 0) return ""

  const lines = ["", "MEMORY CONTEXT — similar events previously reviewed:"]

  for (const ctx of contexts) {
    const overrideNote = ctx.adminOverridden ? " (admin-overridden)" : ""
    lines.push(`- "${ctx.title}" → ${ctx.status}${overrideNote}`)
    if (ctx.adminReason) {
      lines.push(`  Admin reason: ${ctx.adminReason}`)
    }
  }

  lines.push("")
  lines.push(
    "Use these prior decisions as reference. Admin-overridden decisions are stronger signals than LLM-only decisions."
  )

  return lines.join("\n")
}
