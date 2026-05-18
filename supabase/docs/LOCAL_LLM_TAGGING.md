# Local LLM event tagging POC

The `tag-event` function can call an OpenAI-compatible model endpoint instead
of OpenAI. This is intended for small self-hosted models on Railway, especially
Ollama running Qwen3.

## Railway service

Deploy `apps/qwen-ollama` in the same Railway project/environment as the tiny
`@family-events/llm-proxy` service:

- model: `qwen3:1.7b`
- volume: `/root/.ollama`
- private endpoint: `http://qwen3.railway.internal:11434/v1`

Do not expose the Ollama service publicly. Hosted Supabase Edge Functions are
not inside Railway private networking, so they cannot call
`*.railway.internal` directly. Instead, deploy `apps/llm-proxy` on Railway with
a public HTTPS URL and a shared bearer token. The proxy stays in the Railway
project and forwards to the private Ollama service.

Proxy variables:

```bash
LLM_UPSTREAM_BASE_URL=http://${{qwen3.RAILWAY_PRIVATE_DOMAIN}}:11434/v1
LLM_PROXY_API_KEY=<shared-secret>
LLM_UPSTREAM_API_KEY=ollama
```

Deploy the model service from its app directory so Railway picks up
`apps/qwen-ollama/railway.toml`:

```bash
cd apps/qwen-ollama
railway up --detach -m "Deploy Qwen Ollama"
```

Deploy the proxy from its app directory so Railway picks up
`apps/llm-proxy/railway.toml`:

```bash
cd apps/llm-proxy
railway up --detach -m "Deploy local LLM proxy"
```

The web app deploy uses the repository root `railway.toml`:

```bash
railway up --detach -m "Deploy web app"
```

## Supabase function secrets

Set these on the Supabase project running the Edge Functions:

```bash
supabase secrets set AI_PROVIDER=ollama
supabase secrets set AI_BASE_URL=https://<llm-proxy>.up.railway.app/v1
supabase secrets set AI_MODEL=qwen3:1.7b
supabase secrets set AI_API_KEY=<shared-secret>
```

`AI_API_KEY` is ignored by Ollama, but the OpenAI-compatible request shape still
uses a bearer token. For LocalAI, set `AI_PROVIDER=localai` and either
`AI_API_KEY` or `LOCALAI_API_KEY`.

OpenAI remains the default when `AI_PROVIDER` is unset:

```bash
supabase secrets set OPENAI_API_KEY=...
supabase secrets set OPENAI_MODEL=gpt-4o-mini
```

## Smoke test

After deploying `tag-event`, invoke a single manual-review run against one event:

```bash
curl "$SUPABASE_URL/functions/v1/tag-event" \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "event_id": "EVENT_ID",
    "trigger_type": "manual-review"
  }'
```

Expected result:

- `provider` is `ollama`
- `model` is `qwen3:1.7b`
- `status` is `success`, or `fallback` with a concrete local-provider error
- `events.ai_tag_provider` records `ollama`
- latest `event_ai_traces.provider` records `ollama`

## POC success criteria

Run 50 imported events through both OpenAI and Qwen3, then compare:

- valid JSON rate
- tag quality
- average processing time
- fallback count
- Railway memory and CPU pressure

Start with `qwen3:1.7b`. Try `qwen3:4b` only if the JSON rate or tag quality is
not acceptable and Railway memory headroom is stable.
