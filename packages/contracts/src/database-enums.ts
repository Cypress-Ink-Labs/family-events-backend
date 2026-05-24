import type { Enums } from "./database.types.ts"

export const LLM_EVENT_REVIEW_STATUSES = [
  "not_required",
  "pending",
  "succeeded",
  "failed",
  "skipped",
] as const

export const LLM_EVENT_REVIEW_STATUS = {
  NOT_REQUIRED: "not_required",
  PENDING: "pending",
  SUCCEEDED: "succeeded",
  FAILED: "failed",
  SKIPPED: "skipped",
} as const

export const LLM_EVENT_REVIEW_DECISIONS = ["approve", "reject", "needs_admin_review"] as const

export const LLM_EVENT_REVIEW_DECISION = {
  APPROVE: "approve",
  REJECT: "reject",
  NEEDS_ADMIN_REVIEW: "needs_admin_review",
} as const

export type EventProcessingMode = Enums<"event_processing_mode">
export type EventTagQueueStatus = Enums<"event_tag_queue_status">
export type InviteRequestStatus = Enums<"invite_request_status">
export type LlmEventReviewDecision = Enums<"llm_event_review_decision">
export type LlmEventReviewStatus = Enums<"llm_event_review_status">
export type SourceExtractionMode = Enums<"source_extraction_mode">
export type SourceScrapeQueueStatus = Enums<"source_scrape_queue_status">
