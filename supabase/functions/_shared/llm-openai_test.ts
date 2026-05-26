import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert";
import { parseJsonContent, postOpenAiChatCompletion } from "./llm-openai.ts";

Deno.test("postOpenAiChatCompletion posts to chat completions", async () => {
  let url = "";
  const result = await postOpenAiChatCompletion({
    apiKey: "key",
    baseUrl: "https://api.example.com/v1/",
    body: { model: "m", messages: [] },
    fetchImpl: (async (input) => {
      url = String(input);
      return Response.json({
        choices: [{
          finish_reason: "stop",
          message: { content: '{"ok":true}' },
        }],
        usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 },
      });
    }) as typeof fetch,
  });
  assertEquals(url, "https://api.example.com/v1/chat/completions");
  assertEquals(result.content, '{"ok":true}');
  assertEquals(result.usage.totalTokens, 3);
});

Deno.test("postOpenAiChatCompletion reports non-2xx body", async () => {
  await assertRejects(
    () =>
      postOpenAiChatCompletion({
        apiKey: "key",
        baseUrl: "https://api.example.com/v1",
        body: {},
        fetchImpl: (async () =>
          new Response("x".repeat(250), { status: 500 })) as typeof fetch,
        providerName: "openai",
      }),
    Error,
    `openai call failed (500): ${"x".repeat(200)}`,
  );
});

Deno.test("parseJsonContent returns objects and throws on arrays", () => {
  assertEquals(parseJsonContent('{"ok":true}'), { ok: true });
  assertThrows(
    () => parseJsonContent("[1]"),
    Error,
    "provider_json_content_not_object",
  );
});
