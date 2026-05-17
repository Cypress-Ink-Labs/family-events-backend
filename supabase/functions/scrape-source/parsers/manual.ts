import type { SourceParser } from "./_lib/types.ts"

export const manualParser: SourceParser<"manual"> = {
  type: "manual",
  fetchAndParse() {
    return Promise.resolve([])
  },
}
