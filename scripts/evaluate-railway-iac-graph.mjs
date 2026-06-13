#!/usr/bin/env node
import path from "node:path"
import { pathToFileURL } from "node:url"
import { createRailwayContext, project, projectDefinitionToGraph } from "railway/iac"

const filePath = process.argv[2]

if (!filePath) {
  console.error("Usage: evaluate-railway-iac-graph.mjs <railway-config>")
  process.exit(2)
}

try {
  const module = await import(pathToFileURL(path.resolve(filePath)).href)
  const exported = unwrapDefault(module.default ?? module)
  const definition =
    typeof exported === "function" ? await exported(createRailwayContext(), project) : exported
  const graph = projectDefinitionToGraph(definition)

  console.log(
    JSON.stringify({
      ok: true,
      command: "evaluate",
      file: path.resolve(filePath),
      graph,
      diagnostics: [],
    })
  )
} catch (error) {
  console.log(
    JSON.stringify({
      ok: false,
      command: "evaluate",
      file: path.resolve(filePath),
      diagnostics: [
        {
          severity: "error",
          path: "",
          message: error instanceof Error ? error.message : String(error),
        },
      ],
    })
  )
  process.exit(1)
}

function unwrapDefault(value) {
  let current = value
  const seen = new Set()

  while (
    current &&
    typeof current === "object" &&
    "default" in current &&
    !seen.has(current) &&
    Object.keys(current).every((key) => key === "default" || key === "module.exports")
  ) {
    seen.add(current)
    current = current.default
  }

  return current
}
