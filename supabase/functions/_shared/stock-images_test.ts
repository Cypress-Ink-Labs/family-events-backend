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

Deno.test("deriveTitleSearchTerm - limits to 4 words after noise filtering", () => {
  assertEquals(
    deriveTitleSearchTerm("Story Time for Toddlers at the Library"),
    "story time toddlers at"
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

Deno.test("deriveTitleSearchTerm - preserves 'library' with noise filtering", () => {
  assertEquals(
    deriveTitleSearchTerm("Baby Storytime for Toddlers at Main Library"),
    "baby storytime toddlers at"
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
    "yoga park"
  );
});

// Noise word filtering tests
Deno.test("deriveTitleSearchTerm - filters 'free' noise word", () => {
  assertEquals(
    deriveTitleSearchTerm("Free FIFA World Cup Watch Party"),
    "fifa world cup watch"
  );
});

Deno.test("deriveTitleSearchTerm - filters 'annual' noise word", () => {
  assertEquals(
    deriveTitleSearchTerm("Annual Summer Reading Program"),
    "summer reading program"
  );
});

Deno.test("deriveTitleSearchTerm - filters 'the' noise word", () => {
  assertEquals(
    deriveTitleSearchTerm("The Great Outdoors Festival"),
    "great outdoors festival"
  );
});

Deno.test("deriveTitleSearchTerm - filters multiple noise words", () => {
  assertEquals(
    deriveTitleSearchTerm("Weekly Yoga in the Park"),
    "yoga park"
  );
});
