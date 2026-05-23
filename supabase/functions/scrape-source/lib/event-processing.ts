import type { EventProcessingMode, EventSourceRow } from "./types.ts";

export function resolveProcessingMode(
  source: EventSourceRow,
): EventProcessingMode {
  if (source.processing_mode) {
    return source.processing_mode;
  }
  return source.auto_approve ? "auto_approve" : "manual_review";
}
