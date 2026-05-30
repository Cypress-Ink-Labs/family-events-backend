# Railway cron drift guard (Terraform implementation)
#
# This module is used in two ways:
# - GitHub Actions (railway-cron-drift.yml) for PR gating
# - Spacelift as a policy + plan guard
#
# The actual robust parsing + nice diagnostics live in:
#   scripts/spacelift-railway-cron-poc.mjs
#   tests/railway-cron-poc.test.mjs
#
# This file exists primarily so we can use Terraform preconditions + outputs
# as the enforcement mechanism.

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

  # NOTE: These four extractions are intentionally defensive. The canonical,
  # more robust parser (with multiple fallback paths for Railway's meta shape)
  # lives in scripts/spacelift-railway-cron-poc.mjs. These regexes only exist so
  # the Terraform precondition can still act as a hard gate.
  railway_cron_services = {
    for name, svc in local.cron_services_manifest : name => {
      config_path    = svc.config_path
      source_repo    = svc.source_repo
      root_directory = svc.root_directory

      # try(...) turns a regex miss into "" instead of a confusing "did not match"
      # error. Empty values then produce clear diagnostics below.
      builder = upper(
        try(
          regex("builder\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0],
          ""
        )
      )
      dockerfile_path = try(
        regex("dockerfilePath\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0],
        ""
      )
      cron_schedule = try(
        regex("cronSchedule\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0],
        ""
      )
      restart_policy = try(
        regex("restartPolicyType\\s*=\\s*\"([^\"]+)\"", file("${path.module}/../../${svc.config_path}"))[0],
        ""
      )

      required_latest_deployment_status = upper(svc.required_latest_deployment_status)
      forbidden_instance_statuses       = [for status in svc.forbidden_instance_statuses : upper(status)]
      validation_surface                = local.validation_surface
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
                deploymentStopped
                instances {
                  status
                }
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
      root_directory = try(
        edge.node.latestDeployment.meta.rootDirectory,
        ""
      )
      builder = upper(try(
        edge.node.latestDeployment.meta.fileServiceManifest.build.builder,
        try(edge.node.latestDeployment.meta.serviceManifest.build.builder, "")
      ))
      dockerfile_path = try(
        edge.node.latestDeployment.meta.fileServiceManifest.build.dockerfilePath,
        try(edge.node.latestDeployment.meta.serviceManifest.build.dockerfilePath, "")
      )
      restart_policy = upper(try(
        edge.node.latestDeployment.meta.fileServiceManifest.deploy.restartPolicyType,
        try(edge.node.latestDeployment.meta.serviceManifest.deploy.restartPolicyType, "")
      ))
      latest_deployment_status = upper(try(edge.node.latestDeployment.status, ""))
      instance_statuses = [
        for instance in try(edge.node.latestDeployment.instances, []) : upper(instance.status)
        if try(instance.status, "") != ""
      ]
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

  # Human-friendly diagnostics. These are what appear in the Terraform error
  # when the plan precondition fires. The JS version of the validator produces
  # similar (often better) messages and is printed earlier in CI.
  railway_cron_diagnostics = flatten([
    for expected_name, expected in local.railway_cron_services : concat(
      length(local.railway_service_matches[expected_name]) == 0 ? [
        "${expected_name}: live Railway service missing. Expected config from ${expected.config_path}. Fix: ensure the service exists in the Railway POC environment or update cron-services.json."
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].cron_schedule, "") == "" ? [
        "${expected_name}: live Railway metadata missing cronSchedule; expected \"${expected.cron_schedule}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].repo, "") == "" ? [
        "${expected_name}: live Railway metadata missing source repo; expected \"${expected.source_repo}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].root_directory, "") == "" ? [
        "${expected_name}: live Railway metadata missing rootDirectory; expected \"${expected.root_directory}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].builder, "") == "" ? [
        "${expected_name}: live Railway metadata missing build.builder; expected \"${expected.builder}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].dockerfile_path, "") == "" ? [
        "${expected_name}: live Railway metadata missing build.dockerfilePath; expected \"${expected.dockerfile_path}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].restart_policy, "") == "" ? [
        "${expected_name}: live Railway metadata missing restartPolicyType; expected \"${expected.restart_policy}\" from ${expected.config_path}"
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].latest_deployment_status, "") == "" ? [
        "${expected_name}: live Railway metadata missing latestDeployment.status; expected \"${expected.required_latest_deployment_status}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].cron_schedule, null) != null && try(local.railway_service_matches[expected_name][0].cron_schedule, "") != "" && try(local.railway_service_matches[expected_name][0].cron_schedule, "") != expected.cron_schedule ? [
        "${expected_name}: cronSchedule mismatch: expected \"${expected.cron_schedule}\" (from ${expected.config_path}), live \"${try(local.railway_service_matches[expected_name][0].cron_schedule, "")}\". Fix: edit the toml + commit, or redeploy the service in Railway."
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].repo, null) != null && try(local.railway_service_matches[expected_name][0].repo, "") != "" && try(local.railway_service_matches[expected_name][0].repo, "") != expected.source_repo ? [
        "${expected_name}: source repo mismatch: expected \"${expected.source_repo}\" from manifest, live \"${try(local.railway_service_matches[expected_name][0].repo, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].root_directory, null) != null && try(local.railway_service_matches[expected_name][0].root_directory, "") != "" && try(local.railway_service_matches[expected_name][0].root_directory, "") != expected.root_directory ? [
        "${expected_name}: rootDirectory mismatch: expected \"${expected.root_directory}\" from manifest, live \"${try(local.railway_service_matches[expected_name][0].root_directory, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].builder, null) != null && try(local.railway_service_matches[expected_name][0].builder, "") != "" && try(local.railway_service_matches[expected_name][0].builder, "") != expected.builder ? [
        "${expected_name}: build.builder mismatch: expected \"${expected.builder}\" from ${expected.config_path}, live \"${try(local.railway_service_matches[expected_name][0].builder, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].dockerfile_path, null) != null && try(local.railway_service_matches[expected_name][0].dockerfile_path, "") != "" && try(local.railway_service_matches[expected_name][0].dockerfile_path, "") != expected.dockerfile_path ? [
        "${expected_name}: build.dockerfilePath mismatch: expected \"${expected.dockerfile_path}\" from ${expected.config_path}, live \"${try(local.railway_service_matches[expected_name][0].dockerfile_path, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].restart_policy, null) != null && try(local.railway_service_matches[expected_name][0].restart_policy, "") != "" && try(local.railway_service_matches[expected_name][0].restart_policy, "") != expected.restart_policy ? [
        "${expected_name}: restartPolicyType mismatch: expected \"${expected.restart_policy}\" from ${expected.config_path}, live \"${try(local.railway_service_matches[expected_name][0].restart_policy, "")}\""
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && try(local.railway_service_matches[expected_name][0].latest_deployment_status, null) != null && try(local.railway_service_matches[expected_name][0].latest_deployment_status, "") != "" && try(local.railway_service_matches[expected_name][0].latest_deployment_status, "") != expected.required_latest_deployment_status ? [
        "${expected_name}: latestDeployment.status mismatch: expected \"${expected.required_latest_deployment_status}\", live \"${try(local.railway_service_matches[expected_name][0].latest_deployment_status, "")}\". Fix: redeploy the service until it reaches SUCCESS."
      ] : [],
      length(local.railway_service_matches[expected_name]) > 0 && length(setintersection(toset(try(local.railway_service_matches[expected_name][0].instance_statuses, [])), toset(expected.forbidden_instance_statuses))) > 0 ? [
        "${expected_name}: latestDeployment.instances include forbidden statuses ${join(", ", setintersection(toset(try(local.railway_service_matches[expected_name][0].instance_statuses, [])), toset(expected.forbidden_instance_statuses)))}"
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
        repo               = matches[0].repo
        root_directory     = matches[0].root_directory
        builder            = matches[0].builder
        dockerfile_path    = matches[0].dockerfile_path
        cron_schedule      = matches[0].cron_schedule
        restart_policy     = matches[0].restart_policy
        deployment_status  = matches[0].latest_deployment_status
        instance_statuses  = matches[0].instance_statuses
        validation_surface = local.validation_surface
      }
    )
  }
}
