import { assertEquals, assertThrows } from "jsr:@std/assert";
import { isRecord, readEmail, readString, readUuid } from "./validation.ts";

Deno.test("isRecord rejects arrays and null", () => {
  assertEquals(isRecord({}), true);
  assertEquals(isRecord([]), false);
  assertEquals(isRecord(null), false);
});

Deno.test("readString trims and enforces required", () => {
  assertEquals(
    readString({ name: "  Ada  " }, "name", { required: true }),
    "Ada",
  );
  assertThrows(
    () => readString({}, "name", { required: true }),
    Error,
    "missing name",
  );
});

Deno.test("readString enforces maxLength including zero", () => {
  assertEquals(readString({ name: "" }, "name", { maxLength: 0 }), "");
  assertThrows(
    () => readString({ name: "x" }, "name", { maxLength: 0 }),
    Error,
    "invalid name",
  );
});

Deno.test("readEmail lowercases valid email and rejects invalid", () => {
  assertEquals(
    readEmail({ email: "USER@example.COM" }, "email"),
    "user@example.com",
  );
  assertThrows(
    () => readEmail({ email: "not-email" }, "email"),
    Error,
    "invalid email",
  );
});

Deno.test("readUuid accepts UUID values and rejects non-UUIDs", () => {
  assertEquals(
    readUuid({ id: "11111111-2222-4333-8444-555555555555" }, "id"),
    "11111111-2222-4333-8444-555555555555",
  );
  assertThrows(() => readUuid({ id: "nope" }, "id"), Error, "invalid id");
});
