locals {
  validation_surface = "spacelift-before-plan"

  railway_cron_services = {
    cron-tag-queue = {
      config_path        = "apps/cron-tag-queue/railway.toml"
      cron_schedule      = "* * * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = local.validation_surface
    }
    cron-scrape-sources = {
      config_path        = "apps/cron-scrape-sources/railway.toml"
      cron_schedule      = "0 * * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = local.validation_surface
    }
    cron-db-maintenance = {
      config_path        = "apps/cron-db-maintenance/railway.toml"
      cron_schedule      = "15 3 * * *"
      restart_policy     = "ON_FAILURE"
      validation_surface = local.validation_surface
    }
  }
}

output "railway_cron_poc_services" {
  description = "Observe-only Railway cron services covered by the Spacelift POC."
  value       = local.railway_cron_services
}
