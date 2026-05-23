import type {
  LlmReviewConfig,
  LlmReviewProvider,
  LlmReviewProviderInput,
  LlmReviewProviderOutput,
} from "./types.ts";

type FetchLike = typeof fetch;

export class OpenAiCompatibleReviewProvider implements LlmReviewProvider {
  constructor(
    private readonly config: LlmReviewConfig,
    private readonly fetchImpl: FetchLike = fetch,
  ) {}

  async review(
    input: LlmReviewProviderInput,
    signal: AbortSignal,
  ): Promise<LlmReviewProviderOutput> {
    const response = await this.fetchImpl(
      `${this.config.baseUrl}/chat/completions`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${this.config.apiKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: input.model,
          temperature: 0,
          response_format: { type: "json_object" },
          messages: [
            { role: "system", content: input.systemPrompt },
            { role: "user", content: input.userPrompt },
          ],
        }),
        signal,
      },
    );

    if (!response.ok) {
      const body = await response.text().catch(() => "");
      throw new Error(`provider_http_${response.status}:${body.slice(0, 400)}`);
    }

    const payload = await response.json();
    const content = payload?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.trim() === "") {
      throw new Error("provider_empty_content");
    }

    return {
      rawText: content,
      rawResponse: payload,
      provider: this.config.provider,
      model: this.config.model,
    };
  }
}

export function buildLlmReviewProvider(
  config: LlmReviewConfig,
  fetchImpl: FetchLike = fetch,
): LlmReviewProvider {
  return new OpenAiCompatibleReviewProvider(config, fetchImpl);
}
