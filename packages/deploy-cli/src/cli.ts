#!/usr/bin/env node
import { Command } from "commander"
import { registerDeployCommand } from "./commands/deploy"
import { registerDoctorCommand } from "./commands/doctor"
import { registerRollbackPlanCommand } from "./commands/rollback-plan"
import { registerStatusCommand } from "./commands/status"
import { registerTargetsCommand } from "./commands/targets"
import { registerValidateCommand } from "./commands/validate"

const program = new Command()

program
  .name("family-events-deploy")
  .description("Deployment CLI for family-events-ui")
  .version("0.0.1")

registerDeployCommand(program)
registerTargetsCommand(program)
registerValidateCommand(program)
registerDoctorCommand(program)
registerStatusCommand(program)
registerRollbackPlanCommand(program)

const knownCommands = new Set([
  "deploy",
  "targets",
  "validate",
  "doctor",
  "status",
  "rollback-plan",
  "help",
])
if (!process.argv[2] || process.argv[2].startsWith("-") || !knownCommands.has(process.argv[2])) {
  process.argv.splice(2, 0, "deploy")
}

program.parseAsync(process.argv).catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error))
  process.exitCode = 1
})
