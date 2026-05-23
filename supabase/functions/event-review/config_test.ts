import { assertEquals } from "jsr:@std/assert";
import { resolveLlmReviewConfig } from "./config.ts";

function env(values: Record<string, string | undefined>) {
  return {
    get(key: string) {
      return values[key];
    },
  } as Pick<typeof Deno.env, "get">;
}

Deno.test("resolveLlmReviewConfig defaults are production-safe", () => {
  const config = resolveLlmReviewConfig(env({}));

  assertEquals(config.enabled, false);
  assertEquals(config.confidenceThreshold, 0.75);
  assertEquals(config.timeoutMs, 30_000);
  assertEquals(config.maxAttempts, 3);
  assertEquals(config.persistRawResponse, false);
});

Deno.test("resolveLlmReviewConfig invalid threshold fails closed", () => {
  const config = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      LLM_REVIEW_PROVIDER: "openai-compatible",
      LLM_REVIEW_BASE_URL: "https://example.com/v1",
      LLM_REVIEW_MODEL: "gpt-4o-mini",
      LLM_REVIEW_API_KEY: "secret",
      LLM_REVIEW_CONFIDENCE_THRESHOLD: "2",
    }),
  );

  assertEquals(config.enabled, true);
  assertEquals(config.valid, false);
  assertEquals(config.invalidReason, "invalid_confidence_threshold");
});

Deno.test("resolveLlmReviewConfig missing model/api key while enabled fails closed", () => {
  const missingModel = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      LLM_REVIEW_BASE_URL: "https://example.com/v1",
      LLM_REVIEW_API_KEY: "secret",
    }),
  );
  assertEquals(missingModel.valid, false);
  assertEquals(missingModel.invalidReason, "missing_model");

  const missingKey = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      LLM_REVIEW_BASE_URL: "https://example.com/v1",
      LLM_REVIEW_MODEL: "gpt-4o-mini",
    }),
  );
  assertEquals(missingKey.valid, false);
  assertEquals(missingKey.invalidReason, "missing_api_key");
});

Deno.test("resolveLlmReviewConfig invalid timeout or attempts fail closed", () => {
  const invalidTimeout = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      LLM_REVIEW_BASE_URL: "https://example.com/v1",
      LLM_REVIEW_MODEL: "gpt-4o-mini",
      LLM_REVIEW_API_KEY: "secret",
      LLM_REVIEW_TIMEOUT_MS: "nope",
    }),
  );
  assertEquals(invalidTimeout.valid, false);
  assertEquals(invalidTimeout.invalidReason, "invalid_timeout");

  const invalidAttempts = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      LLM_REVIEW_BASE_URL: "https://example.com/v1",
      LLM_REVIEW_MODEL: "gpt-4o-mini",
      LLM_REVIEW_API_KEY: "secret",
      LLM_REVIEW_MAX_ATTEMPTS: "0",
    }),
  );
  assertEquals(invalidAttempts.valid, false);
  assertEquals(invalidAttempts.invalidReason, "invalid_max_attempts");
});

Deno.test("resolveLlmReviewConfig reads AI_* fallbacks", () => {
  const config = resolveLlmReviewConfig(
    env({
      LLM_REVIEW_ENABLED: "true",
      AI_PROVIDER: "openai-compatible",
      AI_BASE_URL: "https://ai.example.com/v1",
      AI_MODEL: "model-x",
      AI_API_KEY: "ai-key",
    }),
  );

  assertEquals(config.provider, "openai-compatible");
  assertEquals(config.baseUrl, "https://ai.example.com/v1");
  assertEquals(config.model, "model-x");
  assertEquals(config.apiKey, "ai-key");
  assertEquals(config.valid, true);
});
