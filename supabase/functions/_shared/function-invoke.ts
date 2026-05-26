export interface InvokeFunctionOptions {
  fetchImpl?: typeof fetch;
  headers?: Record<string, string>;
  serviceRoleKey: string;
  supabaseUrl: string;
  timeoutMs?: number;
  truncateBodyAt?: number;
}

export interface InvokeFunctionResult {
  bodyText: string;
  ok: boolean;
  status: number;
  truncatedBodyText: string;
}

export async function invokeFunction(
  name: string,
  body: unknown,
  options: InvokeFunctionOptions,
): Promise<InvokeFunctionResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const response = await fetchImpl(
    `${options.supabaseUrl.replace(/\/+$/, "")}/functions/v1/${name}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${options.serviceRoleKey}`,
        ...(options.headers ?? {}),
      },
      body: JSON.stringify(body),
      signal: options.timeoutMs == null
        ? undefined
        : AbortSignal.timeout(options.timeoutMs),
    },
  );
  const bodyText = await response.text().catch(() => "");
  const truncateAt = options.truncateBodyAt ?? 200;
  return {
    bodyText,
    ok: response.ok,
    status: response.status,
    truncatedBodyText: bodyText.slice(0, truncateAt),
  };
}
