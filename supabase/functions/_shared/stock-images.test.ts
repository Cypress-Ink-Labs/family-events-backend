import { assertEquals } from "jsr:@std/assert@1";
import { deriveTitleSearchTerm } from "./stock-images.ts";

Deno.test("deriveTitleSearchTerm - strips venue suffix", () => {
  assertEquals(
    deriveTitleSearchTerm("Splash Park at East Side Recreation Center"),
    "splash park"
  );
});

Deno.test("deriveTitleSearchTerm - strips 'presented by' suffix", () => {
  assertEquals(
    deriveTitleSearchTerm("Jazz Concert presented by BREC"),
    "jazz concert"
  );
});

Deno.test("deriveTitleSearchTerm - keeps short titles", () => {
  assertEquals(
    deriveTitleSearchTerm("Community Day"),
    "community day"
  );
});

Deno.test("deriveTitleSearchTerm - limits to 4 words", () => {
  assertEquals(
    deriveTitleSearchTerm("Story Time for Toddlers at the Library"),
    "story time for toddlers"
  );
});

Deno.test("deriveTitleSearchTerm - returns null for very short input", () => {
  assertEquals(deriveTitleSearchTerm("Run"), null);
});

Deno.test("deriveTitleSearchTerm - strips punctuation", () => {
  assertEquals(
    deriveTitleSearchTerm("Kids' Art Workshop!"),
    "kids art workshop"
  );
});

// Library context preservation tests
Deno.test("deriveTitleSearchTerm - preserves 'library' context in title", () => {
  assertEquals(
    deriveTitleSearchTerm("Story Time at West Regional Library"),
    "story time at west"
  );
});

Deno.test("deriveTitleSearchTerm - preserves 'library' with 4-word limit", () => {
  assertEquals(
    deriveTitleSearchTerm("Baby Storytime for Toddlers at Main Library"),
    "baby storytime for toddlers"
  );
});

Deno.test("deriveTitleSearchTerm - preserves 'library' case-insensitive", () => {
  assertEquals(
    deriveTitleSearchTerm("Family Movie Night at LIBRARY"),
    "family movie night at"
  );
});

Deno.test("deriveTitleSearchTerm - preserves 'library' mid-title", () => {
  assertEquals(
    deriveTitleSearchTerm("Library Story Hour presented by BREC"),
    "library story hour"
  );
});

Deno.test("deriveTitleSearchTerm - non-library 'at' suffix still stripped", () => {
  assertEquals(
    deriveTitleSearchTerm("Yoga in the Park at Community Center"),
    "yoga in the park"
  );
});
