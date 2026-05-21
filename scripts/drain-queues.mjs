#!/usr/bin/env node

const usage = `
Usage:
  node scripts/drain-queues.mjs [--source|--tag|--all] [--rounds N] [--pause-ms N] [--no-reap]

Examples:
  node scripts/drain-queues.mjs --all --rounds 20
  node scripts/drain-queues.mjs --source --rounds 10 --pause-ms 1500
`;

const DEFAULT_ROUNDS = 20;
const DEFAULT_PAUSE_MS = 1200;

const envUrl = process.env.SUPABASE_URL ?? process.env.VITE_SUPABASE_URL ?? "";
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";

if (!envUrl || !serviceRoleKey) {
  console.error(
    "Missing environment variables. Required: SUPABASE_URL (or VITE_SUPABASE_URL) and SUPABASE_SERVICE_ROLE_KEY.",
  );
  process.exit(1);
}

const options = {
  mode: "all",
  rounds: DEFAULT_ROUNDS,
  pauseMs: DEFAULT_PAUSE_MS,
  reapFirst: true,
};

for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === "--source") options.mode = "source";
  else if (arg === "--tag") options.mode = "tag";
  else if (arg === "--all") options.mode = "all";
  else if (arg === "--rounds") options.rounds = Number(process.argv[++i]);
  else if (arg === "--pause-ms") options.pauseMs = Number(process.argv[++i]);
  else if (arg === "--no-reap") options.reapFirst = false;
  else if (arg === "--help" || arg === "-h") {
    console.log(usage.trim());
    process.exit(0);
  } else {
    console.error(`Unknown argument: ${arg}`);
    console.log(usage.trim());
    process.exit(1);
  }
}

if (!Number.isInteger(options.rounds) || options.rounds < 1) {
  console.error("--rounds must be a positive integer");
  process.exit(1);
}

if (!Number.isInteger(options.pauseMs) || options.pauseMs < 0) {
  console.error("--pause-ms must be a non-negative integer");
  process.exit(1);
}

const baseHeaders = {
  Authorization: `Bearer ${serviceRoleKey}`,
  apikey: serviceRoleKey,
  "Content-Type": "application/json",
  Accept: "application/json",
};

async function callJson(url, init = {}) {
  const response = await fetch(url, init);
  const bodyText = await response.text();
  const body = bodyText ? JSON.parse(bodyText) : null;

  if (!response.ok) {
    const detail = typeof body === "string" ? body : (body?.error ?? bodyText);
    throw new Error(
      `${response.status} ${response.statusText}: ${detail ?? "empty body"}`,
    );
  }

  return body;
}

async function callFunction(functionName) {
  const url = `${envUrl}/functions/v1/${functionName}`;
  return await callJson(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${serviceRoleKey}`,
    },
    body: "{}",
  });
}

async function callRpc(functionName, args = {}) {
  const response = await fetch(
    `${envUrl}/rest/v1/rpc/${encodeURIComponent(functionName)}`,
    {
      method: "POST",
      headers: {
        ...baseHeaders,
      },
      body: JSON.stringify(args),
    },
  );

  const text = await response.text();
  if (!response.ok) {
    let body = text;
    try {
      const parsed = JSON.parse(text);
      if (typeof parsed === "object" && parsed?.error) {
        body = parsed.error;
      }
    } catch {
      // keep raw text.
    }
    throw new Error(`${response.status} ${response.statusText}: ${body}`);
  }

  if (!text) return null;
  return JSON.parse(text);
}

async function getSummary(viewName, statusOrder) {
  const url = `${envUrl}/rest/v1/${viewName}?select=status,row_count`;
  const rows = await callJson(url, {
    method: "GET",
    headers: baseHeaders,
  });

  const summary = Object.fromEntries(statusOrder.map((status) => [status, 0]));
  for (const row of rows) {
    const status = row?.status;
    if (status in summary) {
      summary[status] = Number(row.row_count ?? 0);
    }
  }

  return summary;
}

async function drainSourceQueue() {
  const functionName = "process-source-queue";
  const reapRpc = "reap_stuck_source_scrape_queue_rows";
  const summaryView = "source_scrape_queue_summary";
  const statuses = ["pending", "processing", "retrying", "succeeded", "dead"];
  const hasWork = (summary) =>
    summary.pending > 0 || summary.retrying > 0 || summary.processing > 0;

  let noProgressRounds = 0;

  for (let round = 1; round <= options.rounds; round++) {
    const summary = await getSummary(summaryView, statuses);
    console.log(
      `[source] round=${round} pending=${summary.pending} retrying=${summary.retrying} processing=${summary.processing}`,
    );

    const hasQueuedWork = hasWork(summary);
    let result = null;
    let reapedNow = 0;
    if (options.reapFirst) {
      const reaped = await callRpc(reapRpc);
      reapedNow = Number(reaped ?? 0);
      console.log(`[source] reaped=${reapedNow}`);
    }

    if (hasQueuedWork) {
      result = await callFunction(functionName);
      if (reapedNow > 0) {
        result.reaped = reapedNow;
      }
      console.log(
        `[source] result claimed=${result.claimed} started=${result.started} released=${result.released} reaped=${result.reaped}`,
      );
    } else {
      result = { claimed: 0, reaped: reapedNow };
      console.log("[source] skip worker, no queued work");
    }

    if ((result.claimed ?? 0) === 0 && (result.reaped ?? 0) === 0) {
      noProgressRounds += 1;
    } else {
      noProgressRounds = 0;
    }

    if (!hasQueuedWork && noProgressRounds >= 2) {
      console.log("[source] no source-queue progress, stopping");
      break;
    }

    if (round < options.rounds)
      await new Promise((r) => setTimeout(r, options.pauseMs));
  }
}

async function drainTagQueue() {
  const functionName = "process-tag-queue";
  const reapRpc = "reap_stuck_tag_queue_rows";
  const summaryView = "event_tag_queue_summary";
  const statuses = ["pending", "processing", "failed", "dead", "succeeded"];
  const hasWork = (summary) => summary.pending > 0 || summary.processing > 0;

  let noProgressRounds = 0;

  for (let round = 1; round <= options.rounds; round++) {
    const summary = await getSummary(summaryView, statuses);
    console.log(
      `[tag] round=${round} pending=${summary.pending} processing=${summary.processing}`,
    );

    const hasQueuedWork = hasWork(summary);
    let result = null;
    let reapedNow = 0;
    if (options.reapFirst) {
      const reaped = await callRpc(reapRpc);
      reapedNow = Number(reaped ?? 0);
      console.log(`[tag] reaped=${reapedNow}`);
    }

    if (hasQueuedWork) {
      result = await callFunction(functionName);
      if (reapedNow > 0) {
        result.reaped = reapedNow;
      }
      console.log(
        `[tag] result claimed=${result.claimed} succeeded=${result.succeeded} failed=${result.failed} dead=${result.dead} reaped=${result.reaped} pending_after=${result.pending_after}`,
      );
    } else {
      result = { claimed: 0, reaped: reapedNow };
      console.log("[tag] skip worker, no queued work");
    }

    if ((result.claimed ?? 0) === 0 && (result.reaped ?? 0) === 0) {
      noProgressRounds += 1;
    } else {
      noProgressRounds = 0;
    }

    if (!hasQueuedWork && noProgressRounds >= 2) {
      console.log("[tag] no tag-queue progress, stopping");
      break;
    }

    if (round < options.rounds)
      await new Promise((r) => setTimeout(r, options.pauseMs));
  }
}

for (const queue of options.mode === "all"
  ? ["source", "tag"]
  : [options.mode]) {
  if (queue === "source") {
    await drainSourceQueue();
  } else {
    await drainTagQueue();
  }
}
