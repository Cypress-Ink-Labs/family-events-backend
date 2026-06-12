import { defineRailway, github, group, preserve, project, service } from "railway/iac";

const repo = "Cypress-Ink-Labs/family-events-backend";

const preservedCronEnv = {
  IS_CRON_ENABLED_URL: preserve(),
  LOG_CRON_RUN_URL: preserve(),
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
      ...preservedCronEnv,
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
    PROCESS_TAG_QUEUE_URL: preserve(),
  });
  const cronScrapeSources = cronService("cron-scrape-sources", "cron/scrape-sources", "0 * * * *", {
    SCRAPE_DUE_SOURCES_URL: preserve(),
  });
  const cronDbMaintenance = cronService("cron-db-maintenance", "cron/db-maintenance", "15 3 * * *", {
    DB_MAINTENANCE_URL: preserve(),
  });
  const cronCleanupStale = cronService("cron-cleanup-stale", "cron/cleanup-stale", "*/30 * * * *", {
    CLEANUP_STALE_RUNS_URL: preserve(),
  });
  const cronEnrichEvents = cronService("cron-enrich-events", "cron/enrich-events", "*/15 * * * *", {
    BACKFILL_EVENT_ENRICHMENT_URL: preserve(),
    UNSPLASH_ACCESS_KEY: preserve(),
  });
  const cronSendReminders = cronService("cron-send-reminders", "cron/send-reminders", "0 11 * * *", {
    SEND_REMINDERS_URL: preserve(),
    VITE_VAPID_PRIVATE_KEY: preserve(),
    VITE_VAPID_PUBLIC_KEY: preserve(),
  });
  const cronWeeklyDigest = cronService("cron-weekly-digest", "cron/weekly-digest", "0 13 * * 1", {
    SEND_WEEKLY_DIGEST_URL: preserve(),
  });
  const cronReviewEvents = cronService("cron-review-events", "cron/review-events", "*/5 * * * *", {
    PROCESS_EVENT_REVIEW_QUEUE_URL: preserve(),
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
