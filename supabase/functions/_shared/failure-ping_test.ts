import { assertEquals, assertStringIncludes } from "jsr:@std/assert"
import { buildFailurePingText, readFailurePingConfig, sendFailurePing } from "./failure-ping.ts"

const fullEnv = (key: string) =>
  ({ TELEGRAM_BOT_TOKEN: "token-1", TELEGRAM_FAILURE_CHAT_ID: "chat-1" })[key]

Deno.test("readFailurePingConfig requires both token and chat id", () => {
  assertEquals(readFailurePingConfig(fullEnv), { botToken: "token-1", chatId: "chat-1" })
  assertEquals(
    readFailurePingConfig((key) => (key === "TELEGRAM_BOT_TOKEN" ? "token-1" : undefined)),
    null
  )
  assertEquals(
    readFailurePingConfig((key) => (key === "TELEGRAM_FAILURE_CHAT_ID" ? "chat-1" : undefined)),
    null
  )
})

Deno.test("buildFailurePingText names the function, subject, and error", () => {
  const text = buildFailurePingText({
    functionName: "process-source-queue",
    kind: "dead_letter",
    subject: "BREC Parks",
    error: "violates check constraint",
  })
  assertStringIncludes(text, "process-source-queue")
  assertStringIncludes(text, "dead-lettered")
  assertStringIncludes(text, "BREC Parks")
  assertStringIncludes(text, "violates check constraint")
})

Deno.test("buildFailurePingText escapes HTML in untrusted fields", () => {
  const text = buildFailurePingText({
    functionName: "send-weekly-digest",
    kind: "function_failed",
    error: 'unexpected <tag> & "quote"',
  })
  assertStringIncludes(text, "&lt;tag&gt; &amp;")
})

Deno.test("sendFailurePing sends exactly one message when configured", async () => {
  const sent: Array<{ botToken: string; chatId: string; text: string }> = []
  const outcome = await sendFailurePing(
    {
      functionName: "process-source-queue",
      kind: "run_failed",
      subject: "Library Events",
      error: "fetch timeout",
    },
    {
      env: fullEnv,
      send: (botToken, chatId, text) => {
        sent.push({ botToken, chatId, text })
        return Promise.resolve({ ok: true })
      },
    }
  )
  assertEquals(outcome, "sent")
  assertEquals(sent.length, 1)
  assertEquals(sent[0].botToken, "token-1")
  assertEquals(sent[0].chatId, "chat-1")
  assertStringIncludes(sent[0].text, "Library Events")
})

Deno.test("sendFailurePing skips (does not throw) when config is missing", async () => {
  const outcome = await sendFailurePing(
    { functionName: "send-reminders", kind: "function_failed", error: "boom" },
    { env: () => undefined, send: () => Promise.reject(new Error("must not be called")) }
  )
  assertEquals(outcome, "skipped")
})

Deno.test("sendFailurePing never throws when the send fails or throws", async () => {
  const failed = await sendFailurePing(
    { functionName: "send-reminders", kind: "function_failed", error: "boom" },
    { env: fullEnv, send: () => Promise.resolve({ ok: false, error: "chat not found" }) }
  )
  assertEquals(failed, "failed")

  const threw = await sendFailurePing(
    { functionName: "send-reminders", kind: "function_failed", error: "boom" },
    { env: fullEnv, send: () => Promise.reject(new Error("network down")) }
  )
  assertEquals(threw, "failed")
})
