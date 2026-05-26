import { assertEquals } from "jsr:@std/assert";
import { resolveSharedLlmConfig } from "./llm-config.ts";

const allowed = new Set(["gpt-4o-mini", "gpt-4.1-nano"]);

function env(values: Record<string, string | undefined>) {
  return { get: (name: string) => values[name] };
}

Deno.test("resolveSharedLlmConfig falls back unknown OpenAI models", () => {
  const config = resolveSharedLlmConfig({
    allowedOpenAiModels: allowed,
    defaultOpenAiModel: "gpt-4o-mini",
  }, env({ AI_MODEL: "bad-model", AI_API_KEY: "key" }));
  assertEquals(config.model, "gpt-4o-mini");
  assertEquals(config.provider, "openai");
  assertEquals(config.configured, true);
});

Deno.test("resolveSharedLlmConfig keeps self-hosted model names", () => {
  const config = resolveSharedLlmConfig(
    {
      allowedOpenAiModels: allowed,
      defaultOpenAiModel: "gpt-4o-mini",
    },
    env({
      AI_PROVIDER: "ollama",
      AI_BASE_URL: "http://localhost:11434/v1/",
      AI_MODEL: "qwen3:1.7b",
    }),
  );
  assertEquals(config.provider, "ollama");
  assertEquals(config.baseUrl, "http://localhost:11434/v1");
  assertEquals(config.model, "qwen3:1.7b");
  assertEquals(config.apiKey, "ollama");
});

Deno.test("resolveSharedLlmConfig does not send OpenAI keys to ollama", () => {
  const config = resolveSharedLlmConfig(
    {
      allowedOpenAiModels: allowed,
      defaultOpenAiModel: "gpt-4o-mini",
    },
    env({
      AI_PROVIDER: "ollama",
      AI_BASE_URL: "http://localhost:11434/v1/",
      AI_MODEL: "qwen3:1.7b",
      OPENAI_API_KEY: "sk-secret",
    }),
  );
  assertEquals(config.apiKey, "ollama");
});

Deno.test("resolveSharedLlmConfig honors disabled db override", () => {
  const config = resolveSharedLlmConfig({
    allowedOpenAiModels: allowed,
    dbOverride: { enabled: false, modelId: "gpt-4.1-nano", provider: "openai" },
    defaultOpenAiModel: "gpt-4o-mini",
  }, env({ AI_API_KEY: "key" }));
  assertEquals(config.enabled, false);
  assertEquals(config.configured, false);
  assertEquals(config.model, "gpt-4.1-nano");
});
