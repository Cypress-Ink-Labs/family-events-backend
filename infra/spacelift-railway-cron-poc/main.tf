variable "railway_environment_id" {
  description = "Railway environment ID to inspect when running live validation."
  type        = string
  default     = ""
}

variable "railway_project_access_token" {
  description = "Railway project token sent with the Project-Access-Token header."
  type        = string
  default     = ""
  sensitive   = true
}

variable "railway_bearer_token" {
  description = "Fallback Railway bearer token sent with the Authorization header."
  type        = string
  default     = ""
  sensitive   = true
}

variable "railway_fixture_path" {
  description = "Optional fixture path, relative to this Terraform root, used for offline validation."
  type        = string
  default     = ""
}

locals {
  validation_surface = "spacelift-before-plan"

  cron_services_manifest = jsondecode(file("${path.module}/cron-services.json"))

  railway_cron_services = {
    for name, svc in local.cron_services_manifest : name => {
      config_path        = svc.config_path
      cron_schedule      = regex("cronSchedule\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0]
      restart_policy     = regex("restartPolicyType\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0]
      validation_surface = local.validation_surface
    }
  }

  railway_graphql_query = <<-GRAPHQL
    query RailwayEnvironment($environmentId: String!) {
      environment(id: $environmentId) {
        serviceInstances(first: 50) {
          edges {
            node {
              serviceName
              serviceId
              cronSchedule
              source {
                repo
                image
              }
              latestDeployment {
                status
                meta
              }
            }
          }
        }
      }
    }
  GRAPHQL

  railway_project_token_configured = nonsensitive(var.railway_project_access_token != "")
  railway_bearer_token_configured  = nonsensitive(var.railway_bearer_token != "")

  railway_auth_mode_configured = (
    (local.railway_project_token_configured && !local.railway_bearer_token_configured) ||
    (!local.railway_project_token_configured && local.railway_bearer_token_configured)
  )

  railway_live_validation_enabled = (
    var.railway_fixture_path == "" &&
    var.railway_environment_id != "" &&
    local.railway_auth_mode_configured
  )

  railway_fixture_file = (
    var.railway_fixture_path == "" ? "" :
    startswith(var.railway_fixture_path, "/") ? var.railway_fixture_path :
    abspath("${path.root}/${var.railway_fixture_path}")
  )

  railway_graphql_response_body = (
    var.railway_fixture_path != "" ? file(local.railway_fixture_file) :
    local.railway_live_validation_enabled ? data.http.railway_environment[0].response_body :
    jsonencode({
      data = {
        environment = {
          serviceInstances = {
            edges = []
          }
        }
      }
      errors = []
    })
  )

  railway_graphql_response = jsondecode(local.railway_graphql_response_body)
  railway_graphql_errors   = try(local.railway_graphql_response.errors, [])
  railway_service_edges    = try(local.railway_graphql_response.data.environment.serviceInstances.edges, [])

  railway_live_services = {
    for edge in local.railway_service_edges : edge.node.serviceName => {
      service_id = try(edge.node.serviceId, "")
      repo       = try(edge.node.source.repo, "")

      cron_schedule = try(edge.node.cronSchedule, "")
      restart_policy = upper(try(
        edge.node.latestDeployment.meta.serviceManifest.deploy.restartPolicyType,
        try(edge.node.latestDeployment.meta.fileServiceManifest.deploy.restartPolicyType, "")
      ))
    }
  }

  railway_service_matches = {
    for expected_name, expected in local.railway_cron_services : expected_name => [
      for service_name, service in local.railway_live_services : merge(service, {
        service_name = service_name
      })
      if service_name == expected_name || startswith(service_name, "${expected_name}-")
    ]
  }

  railway_config_diagnostics = concat(
    var.railway_fixture_path == "" && var.railway_environment_id == "" ? [
      "railway_environment_id is required for live Railway validation."
    ] : [],
    var.railway_fixture_path == "" && !local.railway_auth_mode_configured ? [
      "Set exactly one Railway auth variable: railway_project_access_token or railway_bearer_token."
    ] : []
  )

  railway_graphql_diagnostics = [
    for error in local.railway_graphql_errors : "Railway GraphQL error: ${try(error.message, jsonencode(error))}"
  ]

  railway_cron_diagnostics = flatten([
    for expected_name, expected in local.railway_cron_services : concat(
      length(local.railway_service_matches[expected_name]) == 0 ? [
        "${expected_name}: live Railway service missing; expected config ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].cron_schedule, "") == "" ? [
        "${expected_name}: live Railway metadata missing cronSchedule; expected \"${expected.cron_schedule}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].restart_policy, "") == "" ? [
        "${expected_name}: live Railway metadata missing restartPolicyType; expected \"${expected.restart_policy}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].cron_schedule, "") != "" && try(local.railway_service_matches[expected_name][0].cron_schedule, "") != expected.cron_schedule ? [
        "${expected_name}: cronSchedule mismatch: expected \"${expected.cron_schedule}\" from ${expected.config_path}, live \"${try(local.railway_service_matches[expected_name][0].cron_schedule, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].restart_policy, "") != "" && try(local.railway_service_matches[expected_name][0].restart_policy, "") != expected.restart_policy ? [
        "${expected_name}: restartPolicyType mismatch: expected \"${expected.restart_policy}\" from ${expected.config_path}, live \"${try(local.railway_service_matches[expected_name][0].restart_policy, "")}\""
      ] : []
    )
  ])

  railway_validation_diagnostics = concat(
    local.railway_config_diagnostics,
    local.railway_graphql_diagnostics,
    length(local.railway_config_diagnostics) == 0 && length(local.railway_graphql_diagnostics) == 0 ? local.railway_cron_diagnostics : [],
  )
}

data "http" "railway_environment" {
  count  = local.railway_live_validation_enabled ? 1 : 0
  url    = "https://backboard.railway.com/graphql/v2"
  method = "POST"

  request_headers = merge(
    {
      Content-Type = "application/json"
    },
    local.railway_project_token_configured ? {
      Project-Access-Token = var.railway_project_access_token
      } : {
      Authorization = "Bearer ${var.railway_bearer_token}"
    }
  )

  request_body = jsonencode({
    query = local.railway_graphql_query
    variables = {
      environmentId = var.railway_environment_id
    }
  })
}

output "railway_cron_poc_services" {
  description = "Observe-only Railway cron services covered by the Spacelift POC."
  value       = local.railway_cron_services

  precondition {
    condition     = length(local.railway_validation_diagnostics) == 0
    error_message = join("\n", local.railway_validation_diagnostics)
  }
}

output "railway_cron_live_services" {
  description = "Sanitized live Railway cron metadata used for validation."
  value = {
    for expected_name, matches in local.railway_service_matches : expected_name => (
      length(matches) == 0 ? null : {
        service_name       = matches[0].service_name
        service_id         = matches[0].service_id
        cron_schedule      = matches[0].cron_schedule
        restart_policy     = matches[0].restart_policy
        validation_surface = local.validation_surface
      }
    )
  }
}
