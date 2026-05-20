locals {
  railway_cron_services = {
    cron-tag-queue = {
      config_path        = "apps/cron-tag-queue/railway.toml"
      cron_schedule      = "* * * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = "spacelift-before-plan"
    }
    cron-scrape-sources = {
      config_path        = "apps/cron-scrape-sources/railway.toml"
      cron_schedule      = "0 * * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = "spacelift-before-plan"
    }
    cron-db-maintenance = {
      config_path        = "apps/cron-db-maintenance/railway.toml"
      cron_schedule      = "15 3 * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = "spacelift-before-plan"
    }
  }
}

output "railway_cron_poc_services" {
  description = "Observe-only Railway cron services covered by the Spacelift POC."
  value       = local.railway_cron_services
}
