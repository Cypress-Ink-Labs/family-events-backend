#!/usr/bin/env node

import { createClient } from "@supabase/supabase-js"

const DEFAULT_FUNCTION_NAME = "scrape-source"
const POLL_INTERVAL_MS = 1_000
const POLL_TIMEOUT_MS = 15_000

function requireEnv(name) {
  const value = process.env[name]
  if (!value) {
    console.error(`Missing required environment variable: ${name}`)
    process.exit(1)
  }
  return value
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

async function pollForSourceRun(client, sourceId, startedAtIso) {
  const deadline = Date.now() + POLL_TIMEOUT_MS

  while (Date.now() < deadline) {
    const { data, error } = await client
      .from("source_runs")
      .select("id, source_id, status, events_found, events_imported, events_skipped, created_at")
      .eq("source_id", sourceId)
      .gte("created_at", startedAtIso)
      .order("created_at", { ascending: false })
      .limit(1)

    if (error) {
      throw new Error(`source_runs lookup failed: ${error.message}`)
    }

    if (data?.[0]) {
      return data[0]
    }

    await sleep(POLL_INTERVAL_MS)
  }

  return null
}

async function main() {
  const supabaseUrl = (process.env.VITE_SUPABASE_URL ?? process.env.SUPABASE_URL ?? "").replace(
    /\/+$/,
    ""
  )
  const serviceRoleKey = requireEnv("SUPABASE_SERVICE_ROLE_KEY")
  const sourceId = process.argv[2] ?? process.env.VERIFY_SOURCE_ID
  const functionName = process.env.VERIFY_FUNCTION_NAME ?? DEFAULT_FUNCTION_NAME

  if (!supabaseUrl) {
    console.error("Missing required environment variable: VITE_SUPABASE_URL or SUPABASE_URL")
    process.exit(1)
  }

  if (!sourceId) {
    console.error("Missing source id. Provide as VERIFY_SOURCE_ID or first CLI argument.")
    process.exit(1)
  }

  const startedAtIso = new Date().toISOString()
  const invokeUrl = `${supabaseUrl}/functions/v1/${functionName}`
  const invokeResponse = await fetch(invokeUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ source_id: sourceId }),
  })

  const rawBody = await invokeResponse.text()
  let parsedBody = rawBody
  try {
    parsedBody = JSON.parse(rawBody)
  } catch {
    // Keep raw body for diagnostics.
  }

  if (!invokeResponse.ok) {
    console.error(
      JSON.stringify(
        {
          ok: false,
          stage: "invoke",
          status: invokeResponse.status,
          url: invokeUrl,
          response: parsedBody,
        },
        null,
        2
      )
    )
    process.exit(1)
  }

  const serviceClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const sourceRun = await pollForSourceRun(serviceClient, sourceId, startedAtIso)
  if (!sourceRun) {
    console.error(
      JSON.stringify(
        {
          ok: false,
          stage: "source_runs_lookup",
          message: "No source_runs row observed within timeout.",
          source_id: sourceId,
          started_at: startedAtIso,
        },
        null,
        2
      )
    )
    process.exit(1)
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        function: functionName,
        invoke_status: invokeResponse.status,
        source_run: sourceRun,
      },
      null,
      2
    )
  )
}

await main()
