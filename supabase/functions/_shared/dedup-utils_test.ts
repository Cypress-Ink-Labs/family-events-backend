import { assertEquals, assertNotEquals } from "jsr:@std/assert"
import {
  JACCARD_THRESHOLD,
  canonicalizeTitle,
  eventFingerprint,
  isCrossSourceDuplicate,
  jaccardSimilarity,
  titleTokens,
} from "./dedup-utils.ts"

if (typeof Deno !== "undefined") {
  // ── canonicalizeTitle ──────────────────────────────────────────────────────

  Deno.test("canonicalizeTitle: lowercases input", () => {
    assertEquals(canonicalizeTitle("Family STORY Time"), "family story time")
  })

  Deno.test("canonicalizeTitle: strips punctuation (periods, commas, exclamation)", () => {
    assertEquals(canonicalizeTitle("Fun! Events, Today."), "fun events today")
  })

  Deno.test("canonicalizeTitle: replaces em-dash and en-dash with space", () => {
    // em-dash: —, en-dash: –
    assertEquals(canonicalizeTitle("Family—Fun"), "family fun")
    assertEquals(canonicalizeTitle("Kids–Story"), "kids story")
  })

  Deno.test("canonicalizeTitle: replaces ampersand with space", () => {
    // & → space, then whitespace collapsed → single space
    assertEquals(canonicalizeTitle("Arts & Crafts"), "arts crafts")
    assertEquals(canonicalizeTitle("Arts & Crafts Night"), "arts crafts night")
  })

  Deno.test("canonicalizeTitle: collapses multiple whitespace", () => {
    assertEquals(canonicalizeTitle("  too   many   spaces  "), "too many spaces")
  })

  Deno.test("canonicalizeTitle: handles mixed punctuation and dashes", () => {
    assertEquals(canonicalizeTitle("Story-Time: Family Edition!"), "story time family edition")
  })

  Deno.test("canonicalizeTitle: empty string returns empty string", () => {
    assertEquals(canonicalizeTitle(""), "")
  })

  // ── titleTokens ─────────────────────────────────────────────────────────────

  Deno.test("titleTokens: returns a Set of words", () => {
    const tokens = titleTokens("Family Story Time")
    assertEquals(tokens.has("family"), true)
    assertEquals(tokens.has("story"), true)
    assertEquals(tokens.has("time"), true)
    assertEquals(tokens.size, 3)
  })

  Deno.test("titleTokens: empty string returns empty Set", () => {
    assertEquals(titleTokens("").size, 0)
  })

  // ── jaccardSimilarity ───────────────────────────────────────────────────────

  Deno.test("jaccardSimilarity: identical titles return 1.0", () => {
    assertEquals(jaccardSimilarity("Family Story Time", "Family Story Time"), 1.0)
  })

  Deno.test("jaccardSimilarity: identical after canonicalization return 1.0", () => {
    // "Family Story Time!" vs "family story time" — same canonical tokens
    assertEquals(jaccardSimilarity("Family Story Time!", "family story time"), 1.0)
  })

  Deno.test("jaccardSimilarity: completely disjoint titles return 0.0", () => {
    assertEquals(jaccardSimilarity("Art Workshop", "Science Fair"), 0.0)
  })

  Deno.test("jaccardSimilarity: partial overlap — 2 shared out of 4 unique tokens = 0.5", () => {
    // "family story" ∩ "family time" = {"family"}, union = {"family","story","time"} = 3
    // jaccard = 1/3 ≈ 0.333...
    // Verify an exact fraction case:
    // A = {a, b, c}, B = {a, b, d}  → intersection=2, union=4, jaccard=0.5
    const result = jaccardSimilarity("alpha beta charlie", "alpha beta delta")
    // intersection={alpha,beta}=2, union={alpha,beta,charlie,delta}=4 → 0.5
    assertEquals(result, 0.5)
  })

  Deno.test("jaccardSimilarity: 1 shared out of 3 unique tokens = 1/3", () => {
    // A={family,story}, B={family,time} → intersection=1, union=3 → 1/3
    const result = jaccardSimilarity("family story", "family time")
    const expected = 1 / 3
    assertEquals(Math.abs(result - expected) < 1e-10, true)
  })

  Deno.test("jaccardSimilarity: both empty strings return 0", () => {
    assertEquals(jaccardSimilarity("", ""), 0)
  })

  Deno.test("jaccardSimilarity: 'Family Storytime' vs 'Storytime Family Edition' is below 0.7 threshold", () => {
    // tokens A = {family, storytime} (2)
    // tokens B = {storytime, family, edition} (3)
    // intersection = {family, storytime} = 2
    // union = {family, storytime, edition} = 3
    // jaccard = 2/3 ≈ 0.667, which is below 0.7
    const result = jaccardSimilarity("Family Storytime", "Storytime Family Edition")
    // jaccard = 2/3
    assertEquals(Math.abs(result - 2 / 3) < 1e-10, true)
    assertEquals(result < JACCARD_THRESHOLD, true)
  })

  Deno.test("jaccardSimilarity: 'Family Story Time' vs 'Story Time Family' = 1.0 (same tokens)", () => {
    // Same token set regardless of order
    assertEquals(jaccardSimilarity("Family Story Time", "Story Time Family"), 1.0)
  })

  // ── eventFingerprint ────────────────────────────────────────────────────────

  Deno.test("eventFingerprint: same event with different casing gives same fingerprint", () => {
    const fp1 = eventFingerprint("Family Story Time", "2026-06-20T14:00:00.000Z", "city-1")
    const fp2 = eventFingerprint("FAMILY STORY TIME", "2026-06-20T14:00:00.000Z", "city-1")
    assertEquals(fp1, fp2)
  })

  Deno.test("eventFingerprint: same event with trailing whitespace gives same fingerprint", () => {
    const fp1 = eventFingerprint("Family Story Time", "2026-06-20T14:00:00.000Z", "city-1")
    const fp2 = eventFingerprint("  Family Story Time  ", "2026-06-20T14:00:00.000Z", "city-1")
    assertEquals(fp1, fp2)
  })

  Deno.test("eventFingerprint: minute precision — same minute different seconds match", () => {
    const fp1 = eventFingerprint("Story Time", "2026-06-20T14:00:00.000Z", "city-1")
    const fp2 = eventFingerprint("Story Time", "2026-06-20T14:00:59.999Z", "city-1")
    assertEquals(fp1, fp2)
  })

  Deno.test("eventFingerprint: different cities produce different fingerprints", () => {
    const fp1 = eventFingerprint("Story Time", "2026-06-20T14:00:00.000Z", "city-1")
    const fp2 = eventFingerprint("Story Time", "2026-06-20T14:00:00.000Z", "city-2")
    assertNotEquals(fp1, fp2)
  })

  Deno.test("eventFingerprint: null cityId encoded as 'null'", () => {
    const fp = eventFingerprint("Story Time", "2026-06-20T14:00:00.000Z", null)
    assertEquals(fp.startsWith("null::"), true)
  })

  Deno.test("eventFingerprint: different minutes produce different fingerprints", () => {
    const fp1 = eventFingerprint("Story Time", "2026-06-20T14:00:00.000Z", "city-1")
    const fp2 = eventFingerprint("Story Time", "2026-06-20T14:01:00.000Z", "city-1")
    assertNotEquals(fp1, fp2)
  })

  // ── isCrossSourceDuplicate ──────────────────────────────────────────────────

  Deno.test("isCrossSourceDuplicate: exact fingerprint match returns true", () => {
    assertEquals(
      isCrossSourceDuplicate(
        "Family Story Time",
        "2026-06-20T14:00:00.000Z",
        "Family Story Time",
        "2026-06-20T14:00:00.000Z",
        "city-1"
      ),
      true
    )
  })

  Deno.test("isCrossSourceDuplicate: fingerprint match despite different casing", () => {
    assertEquals(
      isCrossSourceDuplicate(
        "FAMILY STORY TIME",
        "2026-06-20T14:00:00.000Z",
        "family story time",
        "2026-06-20T14:00:00.000Z",
        "city-1"
      ),
      true
    )
  })

  Deno.test("isCrossSourceDuplicate: high Jaccard overlap (1.0) is a duplicate", () => {
    // titles are identical after canonicalization → jaccard = 1.0 >= 0.7
    assertEquals(
      isCrossSourceDuplicate(
        "Art Workshop",
        "2026-06-20T10:00:00.000Z",
        "Art Workshop",
        "2026-06-20T10:00:00.000Z",
        "city-1"
      ),
      true
    )
  })

  Deno.test("isCrossSourceDuplicate: partial overlap above threshold (0.5 >= 0.5) with custom threshold", () => {
    // "alpha beta charlie" vs "alpha beta delta" → jaccard = 0.5
    // With threshold=0.5 this should match
    assertEquals(
      isCrossSourceDuplicate(
        "alpha beta charlie",
        "2026-06-20T10:00:00.000Z",
        "alpha beta delta",
        "2026-06-20T10:30:00.000Z",
        "city-1",
        0.5
      ),
      true
    )
  })

  Deno.test("isCrossSourceDuplicate: below default threshold (0.333 < 0.7) is not a duplicate", () => {
    // "family story" vs "family time" → jaccard = 1/3 ≈ 0.333
    assertEquals(
      isCrossSourceDuplicate(
        "family story",
        "2026-06-20T10:00:00.000Z",
        "family time",
        "2026-06-20T10:00:00.000Z",
        "city-1"
      ),
      false
    )
  })

  Deno.test("isCrossSourceDuplicate: completely disjoint titles is not a duplicate", () => {
    assertEquals(
      isCrossSourceDuplicate(
        "Art Workshop",
        "2026-06-20T10:00:00.000Z",
        "Science Fair",
        "2026-06-20T10:00:00.000Z",
        "city-1"
      ),
      false
    )
  })

  Deno.test("isCrossSourceDuplicate: 'Family Storytime' vs 'Storytime Family Edition' is NOT duplicate at 0.7 threshold", () => {
    // jaccard = 2/3 ≈ 0.667, below 0.7
    // fingerprints differ too (different canonical titles)
    // Real-world ticket example — call this out honestly: this pair will NOT be deduped.
    assertEquals(
      isCrossSourceDuplicate(
        "Family Storytime",
        "2026-06-20T10:00:00.000Z",
        "Storytime Family Edition",
        "2026-06-20T10:00:00.000Z",
        "city-1"
      ),
      false
    )
  })

  Deno.test("isCrossSourceDuplicate: JACCARD_THRESHOLD const is 0.7", () => {
    assertEquals(JACCARD_THRESHOLD, 0.7)
  })
}
