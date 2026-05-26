import { assertEquals, assertThrows } from "jsr:@std/assert";
import { boolEnv, intEnv, optionalEnv, requiredEnv, urlEnv } from "./env.ts";

function env(values: Record<string, string | undefined>) {
  return {
    get(name: string) {
      return values[name];
    },
  };
}

Deno.test("requiredEnv returns trimmed value", () => {
  assertEquals(requiredEnv("NAME", env({ NAME: " value " })), "value");
});

Deno.test("requiredEnv throws configured message", () => {
  assertThrows(
    () => requiredEnv("NAME", env({})),
    Error,
    "NAME not configured",
  );
});

Deno.test("optionalEnv returns empty string for missing values", () => {
  assertEquals(optionalEnv("NAME", env({})), "");
});

Deno.test("intEnv returns fallback for missing and invalid values", () => {
  assertEquals(intEnv("N", 7, env({})), 7);
  assertEquals(intEnv("N", 7, env({ N: "abc" })), 7);
  assertEquals(intEnv("N", 7, env({ N: "12.8" })), 12);
});

Deno.test("boolEnv parses true and false", () => {
  assertEquals(boolEnv("B", false, env({ B: "true" })), true);
  assertEquals(boolEnv("B", true, env({ B: "false" })), false);
  assertEquals(boolEnv("B", true, env({ B: "wat" })), true);
});

Deno.test("urlEnv returns fallback for blank values", () => {
  assertEquals(
    urlEnv("URL", "https://example.com", env({ URL: " " })),
    "https://example.com",
  );
});
