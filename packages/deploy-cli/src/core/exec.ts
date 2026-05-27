import { execa, ExecaError } from "execa"
import { AuthError, CancelledError, ValidationError } from "./errors"
import { redact } from "./redaction"
import type { CommandRecord, ProcessResult, ProcessRunner } from "./types"

export class ExecaProcessRunner implements ProcessRunner {
  readonly records: CommandRecord[] = []
  private readonly rootDir: string
  private readonly dryRun: boolean
  private readonly cancelSignal?: AbortSignal
  private readonly streamOutput: boolean

  constructor(rootDir: string, dryRun: boolean, cancelSignal?: AbortSignal, streamOutput = false) {
    this.rootDir = rootDir
    this.dryRun = dryRun
    this.cancelSignal = cancelSignal
    this.streamOutput = streamOutput
  }

  async run(
    command: string,
    args: string[],
    options: { cwd?: string; allowFailure?: boolean } = {}
  ): Promise<ProcessResult> {
    const cwd = options.cwd ?? this.rootDir
    const record: CommandRecord = { command, args, cwd, dryRun: this.dryRun }
    this.records.push(record)

    if (this.dryRun) {
      record.exitCode = 0
      return { stdout: "", stderr: "", exitCode: 0 }
    }

    try {
      const output = this.streamOutput ? (["inherit", "pipe"] as const) : "pipe"
      const result = await execa(command, args, {
        cwd,
        cancelSignal: this.cancelSignal,
        reject: false,
        all: false,
        stdout: output,
        stderr: output,
        env: { ...process.env, FORCE_COLOR: process.env.FORCE_COLOR ?? "1" },
      })
      const exitCode = result.exitCode ?? 1
      record.exitCode = exitCode
      const processResult = {
        stdout: redact(result.stdout),
        stderr: redact(result.stderr),
        exitCode,
      }
      if (exitCode !== 0 && !options.allowFailure) {
        throw new ValidationError(`${command} ${args.join(" ")} failed with exit code ${exitCode}`)
      }
      return processResult
    } catch (error) {
      if (this.cancelSignal?.aborted) {
        throw new CancelledError()
      }
      if (error instanceof ExecaError && error.code === "ENOENT") {
        throw new ValidationError(`Required executable not found: ${command}`)
      }
      throw error
    }
  }
}

export async function requireExecutable(runner: ProcessRunner, executable: string): Promise<void> {
  const result = await runner.run(executable, ["--version"], { allowFailure: true })
  if (result.exitCode !== 0) {
    throw new ValidationError(`Required executable not available: ${executable}`)
  }
}

export async function requireRailwayAuth(runner: ProcessRunner): Promise<void> {
  const result = await runner.run("railway", ["whoami"], { allowFailure: true })
  if (result.exitCode !== 0) {
    throw new AuthError("Railway CLI is not authenticated. Run: railway login")
  }
}
