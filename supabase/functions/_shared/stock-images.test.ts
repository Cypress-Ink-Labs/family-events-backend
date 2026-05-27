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
