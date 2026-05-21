import type { SourceParser } from "./_lib/types.ts";

export const manualParser: SourceParser<"manual"> = {
  type: "manual",
  fetchArtifact(source) {
    return Promise.resolve({
      url: source.url,
      contentType: "text/plain",
      body: "",
    });
  },
  extractEvents() {
    return Promise.resolve([]);
  },
  fetchAndParse() {
    return Promise.resolve([]);
  },
};
