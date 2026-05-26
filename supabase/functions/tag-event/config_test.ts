import { assertEquals } from "jsr:@std/assert";
import {
  resolveTagEventAiConfig,
  resolveTagEventOpenAiModel,
} from "./config.ts";

Deno.test("resolveTagEventOpenAiModel falls back to default", () => {
  assertEquals(resolveTagEventOpenAiModel("bad-model"), "gpt-4o-mini");
  assertEquals(resolveTagEventOpenAiModel("gpt-4.1-nano"), "gpt-4.1-nano");
});

Deno.test("resolveTagEventAiConfig keeps disabled db model but unconfigures", () => {
  const config = resolveTagEventAiConfig({
    enabled: false,
    modelId: "gpt-4.1-nano",
    provider: "openai",
  });
  assertEquals(config.configured, false);
  assertEquals(config.model, "gpt-4.1-nano");
});
