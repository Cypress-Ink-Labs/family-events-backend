/**
 * Memory context retrieval for adaptive pipeline.
 *
 * Fetches similar events and their associated tags, admin corrections,
 * and review outcomes to build few-shot context for LLM prompts.
 */

import type { SupabaseClient } from "@supabase/supabase-js";
import { logEdgeEvent } from "./logger.ts";

// ── Types ────────────────────────────────────────────────────────────────────

export interface SimilarEventTag {
  slug: string;
  name: string;
  source: "ai" | "admin";
  confidence: number;
}

export interface SimilarEventTagContext {
  eventId: string;
  title: string;
  cosineDistance: number;
  tags: SimilarEventTag[];
  adminCorrected: boolean;
  adminReason: string | null;
}

export interface SimilarEventReviewContext {
  eventId: string;
  title: string;
  cosineDistance: number;
  status: string;
  llmReviewDecision: string | null;
  adminOverridden: boolean;
  adminDecision: string | null;
  adminReason: string | null;
}

export interface ReviewConfidenceAdjustment {
  delta: number;
  reason: string;
  approvedCount: number;
  rejectedCount: number;
  totalSimilar: number;
}

// ── Feature flag check ───────────────────────────────────────────────────────

export async function isMemoryFeatureEnabled(
  supabase: SupabaseClient,
  feature: "tag-memory" | "review-memory" | "source-auto-reject",
): Promise<boolean> {
  try {
    const { data, error } = await supabase
      .from("ai_feature_config")
      .select("enabled")
      .eq("feature", feature)
      .maybeSingle();
    if (error || !data) return false;
    return (data as { enabled: boolean }).enabled === true;
  } catch {
    return false;
  }
}

// ── Tagging memory context ───────────────────────────────────────────────────

interface SimilarEventRow {
  event_id: string;
  title: string;
  cosine_distance: number;
  source_id: string | null;
  city_id: string | null;
  status: string;
}

interface EventTagRow {
  tag_id: string;
  confidence: number;
  is_manual_override: boolean;
  tags: { slug: string; name: string } | null;
}

interface AdminDecisionRow {
  decision_type: string;
  new_tags: unknown;
  reason: string | null;
  created_at: string;
}

export async function fetchSimilarEventTagContext(
  supabase: SupabaseClient,
  embedding: number[],
  excludeEventId: string | null,
  cityId: string | null,
  limit = 5,
): Promise<SimilarEventTagContext[]> {
  const vectorStr = `[${embedding.join(",")}]`;

  const { data: similar, error: simError } = await supabase
    .rpc("find_similar_events", {
      p_embedding: vectorStr,
      p_limit: limit,
      p_threshold: 0.3,
      p_exclude_event_id: excludeEventId,
      p_city_id: cityId,
    });

  if (simError) throw simError;
  if (!similar || (similar as SimilarEventRow[]).length === 0) return [];

  const results: SimilarEventTagContext[] = [];

  for (const row of similar as SimilarEventRow[]) {
    // Fetch tags for this event
    const { data: tagRows, error: tagError } = await supabase
      .from("event_tags")
      .select("tag_id, confidence, is_manual_override, tags(slug, name)")
      .eq("event_id", row.event_id);

    if (tagError) {
      logEdgeEvent("warn", "memory-context: failed to fetch tags for similar event", {
        event_id: row.event_id,
        error: tagError.message,
      });
      continue;
    }

    const tags: SimilarEventTag[] = ((tagRows ?? []) as unknown as EventTagRow[])
      .filter((t) => t.tags)
      .map((t) => ({
        slug: t.tags!.slug,
        name: t.tags!.name,
        source: t.is_manual_override ? "admin" as const : "ai" as const,
        confidence: t.confidence,
      }))
      .sort((a, b) => {
        // Admin corrections first, then by confidence
        if (a.source !== b.source) return a.source === "admin" ? -1 : 1;
        return b.confidence - a.confidence;
      });

    // Check for admin corrections
    const { data: decisions } = await supabase
      .from("admin_event_decisions")
      .select("decision_type, new_tags, reason, created_at")
      .eq("event_id", row.event_id)
      .in("decision_type", ["tag_edit", "status_and_tags"])
      .order("created_at", { ascending: false })
      .limit(1);

    const latestDecision = (decisions as AdminDecisionRow[] | null)?.[0] ?? null;

    results.push({
      eventId: row.event_id,
      title: row.title.slice(0, 100),
      cosineDistance: row.cosine_distance,
      tags,
      adminCorrected: latestDecision !== null || tags.some((t) => t.source === "admin"),
      adminReason: latestDecision?.reason ?? null,
    });
  }

  return results;
}

// ── Review memory context ────────────────────────────────────────────────────

export async function fetchSimilarReviewContext(
  supabase: SupabaseClient,
  embedding: number[],
  excludeEventId: string | null,
  cityId: string | null,
  limit = 5,
): Promise<{ contexts: SimilarEventReviewContext[]; confidenceAdjustment: ReviewConfidenceAdjustment }> {
  const vectorStr = `[${embedding.join(",")}]`;

  const { data: similar, error: simError } = await supabase
    .rpc("find_similar_events", {
      p_embedding: vectorStr,
      p_limit: limit,
      p_threshold: 0.3,
      p_exclude_event_id: excludeEventId,
      p_city_id: cityId,
    });

  if (simError) throw simError;

  const similarRows = (similar ?? []) as SimilarEventRow[];
  if (similarRows.length === 0) {
    return {
      contexts: [],
      confidenceAdjustment: { delta: 0, reason: "no similar events found", approvedCount: 0, rejectedCount: 0, totalSimilar: 0 },
    };
  }

  const contexts: SimilarEventReviewContext[] = [];
  let approvedCount = 0;
  let rejectedCount = 0;

  for (const row of similarRows) {
    // Fetch event's review state
    const { data: eventRow, error: evtError } = await supabase
      .from("events")
      .select("status, llm_review_decision")
      .eq("id", row.event_id)
      .maybeSingle();

    if (evtError || !eventRow) continue;

    const evt = eventRow as { status: string; llm_review_decision: string | null };

    // Check for admin override
    const { data: decisions } = await supabase
      .from("admin_event_decisions")
      .select("decision_type, new_status, reason, created_at")
      .eq("event_id", row.event_id)
      .eq("decision_type", "status_change")
      .order("created_at", { ascending: false })
      .limit(1);

    const latestAdminDecision = (decisions as Array<{
      decision_type: string;
      new_status: string;
      reason: string | null;
    }> | null)?.[0] ?? null;

    const adminOverridden = latestAdminDecision !== null;

    // Count outcomes based on final status
    if (evt.status === "published") approvedCount++;
    if (evt.status === "rejected") rejectedCount++;

    contexts.push({
      eventId: row.event_id,
      title: row.title.slice(0, 100),
      cosineDistance: row.cosine_distance,
      status: evt.status,
      llmReviewDecision: evt.llm_review_decision,
      adminOverridden,
      adminDecision: latestAdminDecision?.new_status ?? null,
      adminReason: latestAdminDecision?.reason ?? null,
    });
  }

  const totalSimilar = contexts.length;
  let delta = 0;
  let reason = "mixed outcomes among similar events";

  if (totalSimilar > 0) {
    const approvedRate = approvedCount / totalSimilar;
    const rejectedRate = rejectedCount / totalSimilar;

    if (approvedRate >= 0.8) {
      delta = 0.1;
      reason = `${approvedCount}/${totalSimilar} similar events were approved`;
    } else if (rejectedRate >= 0.8) {
      delta = -0.1;
      reason = `${rejectedCount}/${totalSimilar} similar events were rejected`;
    }
  }

  return {
    contexts,
    confidenceAdjustment: { delta, reason, approvedCount, rejectedCount, totalSimilar },
  };
}

// ── Prompt formatting helpers ────────────────────────────────────────────────

export function formatTagMemoryPrompt(contexts: SimilarEventTagContext[]): string {
  if (contexts.length === 0) return "";

  const lines = [
    "",
    "MEMORY CONTEXT — similar events previously processed:",
  ];

  for (const ctx of contexts) {
    const tagList = ctx.tags.map((t) => {
      const suffix = t.source === "admin" ? " (admin-corrected)" : "";
      return `${t.slug}${suffix}`;
    }).join(", ");

    const correctionNote = ctx.adminCorrected ? " [ADMIN CORRECTED]" : "";
    lines.push(`- "${ctx.title}" → tags: [${tagList}]${correctionNote}`);
    if (ctx.adminReason) {
      lines.push(`  Admin reason: ${ctx.adminReason}`);
    }
  }

  lines.push("");
  lines.push("Use these examples as reference when classifying the current event. Admin-corrected tags are higher-quality signals.");

  return lines.join("\n");
}

export function formatReviewMemoryPrompt(contexts: SimilarEventReviewContext[]): string {
  if (contexts.length === 0) return "";

  const lines = [
    "",
    "MEMORY CONTEXT — similar events previously reviewed:",
  ];

  for (const ctx of contexts) {
    const overrideNote = ctx.adminOverridden ? " (admin-overridden)" : "";
    lines.push(`- "${ctx.title}" → ${ctx.status}${overrideNote}`);
    if (ctx.adminReason) {
      lines.push(`  Admin reason: ${ctx.adminReason}`);
    }
  }

  lines.push("");
  lines.push("Use these prior decisions as reference. Admin-overridden decisions are stronger signals than LLM-only decisions.");

  return lines.join("\n");
}
