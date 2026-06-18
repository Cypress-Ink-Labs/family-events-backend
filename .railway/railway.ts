import { defineRailway, github, group, preserve, project, service } from "railway/iac";

const repo = "Cypress-Ink-Labs/family-events-backend";

// Production Supabase project. Each cron container curls one of these endpoints
// (with the service-role bearer) on every scheduled run.
//
// These URLs are SET here rather than preserve()-d from the Railway dashboard so
// every cron's target URL lives in version control. A missing/cleared dashboard
// value used to silently crash a job — e.g. an empty SEND_WEEKLY_DIGEST_URL made
// cron-runner.sh exit with "missing URL arg" and the service CRASHED. Setting them
// in IaC makes that class of misconfiguration impossible.
//
// Secrets (service-role key, image-provider keys, VAPID keys) stay preserve() —
// never commit secret values.
const SUPABASE_URL = "https://ufrjcnozcapskjtoakvf.supabase.co";
const fnUrl = (name: string) => `${SUPABASE_URL}/functions/v1/${name}`;
const rpcUrl = (name: string) => `${SUPABASE_URL}/rest/v1/rpc/${name}`;

// Shared by every cron service. The kill-switch RPC + run logger are the same
// across jobs; the service-role key is a secret and stays preserved.
const baseCronEnv = {
  IS_CRON_ENABLED_URL: rpcUrl("is_cron_enabled"),
  LOG_CRON_RUN_URL: fnUrl("log-cron-run"),
  SUPABASE_SERVICE_ROLE_KEY: preserve(),
};

const cronBuild = (rootDirectory: string) => ({
  builder: "DOCKERFILE" as const,
  dockerfilePath: "Dockerfile",
  watchPatterns: [`${rootDirectory}/**`],
});

const cronDeploy = (cronSchedule: string) => ({
  cronSchedule,
  restartPolicyType: "ON_FAILURE" as const,
});

const cronService = (name: string, rootDirectory: string, cronSchedule: string, env = {}) =>
  service(name, {
    source: github(repo, { rootDirectory }),
    build: cronBuild(rootDirectory),
    deploy: cronDeploy(cronSchedule),
    env: {
      ...baseCronEnv,
      ...env,
    },
  });

export default defineRailway(() => {
  const web = service("web", {
    source: github(repo),
    build: {
      builder: "RAILPACK",
    },
    deploy: {
      restartPolicyType: "ON_FAILURE" as const,
    },
  });

  const cronTagQueue = cronService("cron-tag-queue", "cron/tag-queue", "*/5 * * * *", {
    PROCESS_TAG_QUEUE_URL: fnUrl("process-tag-queue"),
  });
  const cronScrapeSources = cronService("cron-scrape-sources", "cron/scrape-sources", "0 * * * *", {
    SCRAPE_DUE_SOURCES_URL: fnUrl("scrape-due-sources"),
  });
  const cronDbMaintenance = cronService(
    "cron-db-maintenance",
    "cron/db-maintenance",
    "15 3 * * *",
    {
      DB_MAINTENANCE_URL: fnUrl("db-maintenance"),
    },
  );
  const cronCleanupStale = cronService("cron-cleanup-stale", "cron/cleanup-stale", "*/30 * * * *", {
    CLEANUP_STALE_RUNS_URL: fnUrl("cleanup-stale-runs"),
  });
  const cronEnrichEvents = cronService("cron-enrich-events", "cron/enrich-events", "*/15 * * * *", {
    BACKFILL_EVENT_ENRICHMENT_URL: fnUrl("backfill-event-enrichment"),
    UNSPLASH_ACCESS_KEY: preserve(),
  });
  const cronSendReminders = cronService(
    "cron-send-reminders",
    "cron/send-reminders",
    "0 11 * * *",
    {
      SEND_REMINDERS_URL: fnUrl("send-reminders"),
      VITE_VAPID_PRIVATE_KEY: preserve(),
      VITE_VAPID_PUBLIC_KEY: preserve(),
    },
  );
  const cronWeeklyDigest = cronService("cron-weekly-digest", "cron/weekly-digest", "0 13 * * 1", {
    SEND_WEEKLY_DIGEST_URL: fnUrl("send-weekly-digest"),
  });
  const cronReviewEvents = cronService("cron-review-events", "cron/review-events", "*/5 * * * *", {
    PROCESS_EVENT_REVIEW_QUEUE_URL: fnUrl("process-event-review-queue"),
  });

  const cronJobs = group("Cron Jobs", [
    cronTagQueue,
    cronScrapeSources,
    cronDbMaintenance,
    cronCleanupStale,
    cronEnrichEvents,
    cronSendReminders,
    cronWeeklyDigest,
    cronReviewEvents,
  ]);

  return project("family-events", {
    resources: [web, cronJobs],
  });
});
