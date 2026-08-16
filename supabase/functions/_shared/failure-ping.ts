// Production readiness program U3: operator failure ping over Telegram.
//
// Life-support alerting for the old pipeline (R14): one ping per failed run,
// one per new dead-letter, and one per crashed scheduled function — so the
// operator learns about failures from Telegram, not from opening the admin
// page. The ping must never break the pipeline it monitors: every path here
// degrades to a logged warning.
//
// Config (Supabase function secrets):
//   TELEGRAM_BOT_TOKEN       — existing bot token (shared with user notifications)
//   TELEGRAM_FAILURE_CHAT_ID — operator chat/channel that receives failure pings

import { logEdgeEvent } from "./logger.ts"
import { sendTelegramMessage, type TelegramResult } from "./telegram.ts"

export type FailurePingKind = "run_failed" | "dead_letter" | "function_failed"

export interface FailurePingInput {
  functionName: string
  kind: FailurePingKind
  /** Human identity of the failing item, e.g. the source name. */
  subject?: string
  error: string
}

export interface FailurePingConfig {
  botToken: string
  chatId: string
}

export interface FailurePingOptions {
  env?: (key: string) => string | undefined
  send?: (botToken: string, chatId: string, text: string) => Promise<TelegramResult>
}

const KIND_LABELS: Record<FailurePingKind, string> = {
  run_failed: "run failed",
  dead_letter: "dead-lettered",
  function_failed: "function crashed",
}

export function readFailurePingConfig(
  env: (key: string) => string | undefined = (key) => Deno.env.get(key)
): FailurePingConfig | null {
  const botToken = env("TELEGRAM_BOT_TOKEN") ?? ""
  const chatId = env("TELEGRAM_FAILURE_CHAT_ID") ?? ""
  if (!botToken || !chatId) return null
  return { botToken, chatId }
}

function escapeHtml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
}

export function buildFailurePingText(input: FailurePingInput): string {
  const lines = [
    `⚠️ <b>${escapeHtml(input.functionName)}</b>: ${KIND_LABELS[input.kind]}`,
    input.subject ? `source: ${escapeHtml(input.subject)}` : null,
    `error: ${escapeHtml(input.error.slice(0, 500))}`,
  ]
  return lines.filter((line) => line !== null).join("\n")
}

/**
 * Send a failure ping to the operator. Never throws; returns the outcome so
 * callers/tests can assert on it.
 *
 * - "sent"    — Telegram accepted the message.
 * - "skipped" — config missing; a warning was logged and the caller continues.
 * - "failed"  — send attempted but failed; logged, caller continues.
 */
export async function sendFailurePing(
  input: FailurePingInput,
  opts: FailurePingOptions = {}
): Promise<"sent" | "skipped" | "failed"> {
  try {
    const config = readFailurePingConfig(opts.env)
    if (!config) {
      logEdgeEvent("warn", "failure ping skipped: telegram config missing", {
        function: input.functionName,
        kind: input.kind,
      })
      return "skipped"
    }

    const send = opts.send ?? sendTelegramMessage
    const result = await send(config.botToken, config.chatId, buildFailurePingText(input))
    if (!result.ok) {
      logEdgeEvent("warn", "failure ping send failed", {
        function: input.functionName,
        kind: input.kind,
        error: result.error ?? "unknown",
      })
      return "failed"
    }
    return "sent"
  } catch (err) {
    logEdgeEvent("warn", "failure ping threw", {
      function: input.functionName,
      kind: input.kind,
      error: err instanceof Error ? err.message : String(err),
    })
    return "failed"
  }
}
