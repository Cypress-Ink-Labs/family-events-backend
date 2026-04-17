import { describe, expect, it } from "vitest"
import { decodeHtml, dedupKey, extractPrice, parseIcalDate, parseIsoDate, stripHtml } from "./parsing"

describe("parseIsoDate", () => {
  it("normalizes a valid ISO string to ISO UTC", () => {
    const result = parseIsoDate("2026-04-15T14:30:00Z")
    expect(result).toBe("2026-04-15T14:30:00.000Z")
  })

  it("returns null for null or undefined input", () => {
    expect(parseIsoDate(null)).toBeNull()
    expect(parseIsoDate(undefined)).toBeNull()
    expect(parseIsoDate("")).toBeNull()
  })

  it("returns null for an unparseable string", () => {
    expect(parseIsoDate("not a date")).toBeNull()
  })

  it("accepts common readable date formats", () => {
    // new Date() parses "Apr 15, 2026" in JS
    expect(parseIsoDate("Apr 15, 2026")).not.toBeNull()
  })
})

describe("parseIcalDate", () => {
  it("parses compact date-only (YYYYMMDD) as midnight UTC", () => {
    expect(parseIcalDate("20260415")).toBe("2026-04-15T00:00:00.000Z")
  })

  it("parses compact datetime with Z (YYYYMMDDTHHMMSSZ)", () => {
    expect(parseIcalDate("20260415T143000Z")).toBe("2026-04-15T14:30:00.000Z")
  })

  it("parses compact datetime without Z as UTC", () => {
    // "20260415T143000" — no trailing Z. Treated as UTC for consistency across environments.
    expect(parseIcalDate("20260415T143000")).toBe("2026-04-15T14:30:00.000Z")
  })

  it("falls back to parseIsoDate for other formats", () => {
    expect(parseIcalDate("2026-04-15T14:30:00Z")).toBe("2026-04-15T14:30:00.000Z")
  })

  it("returns null for null or invalid input", () => {
    expect(parseIcalDate(null)).toBeNull()
    expect(parseIcalDate("garbage")).toBeNull()
  })
})

describe("decodeHtml", () => {
  it("decodes common named entities", () => {
    expect(decodeHtml("A &amp; B")).toBe("A & B")
    expect(decodeHtml("&lt;tag&gt;")).toBe("<tag>")
    expect(decodeHtml("&quot;hi&quot;")).toBe('"hi"')
    expect(decodeHtml("it&#39;s")).toBe("it's")
  })

  it("leaves non-entity text untouched", () => {
    expect(decodeHtml("plain text")).toBe("plain text")
  })
})

describe("stripHtml", () => {
  it("removes tags and collapses whitespace", () => {
    expect(stripHtml("<p>Hello <b>world</b></p>")).toBe("Hello world")
  })

  it("decodes entities after stripping tags", () => {
    expect(stripHtml("<p>A &amp; B</p>")).toBe("A & B")
  })

  it("trims leading and trailing whitespace", () => {
    expect(stripHtml("   <span>text</span>   ")).toBe("text")
  })

  it("handles self-closing tags", () => {
    expect(stripHtml("before<br/>after")).toBe("before after")
  })
})

describe("extractPrice", () => {
  it("detects 'free' keyword", () => {
    expect(extractPrice("Free concert")).toEqual({ price: null, isFree: true })
  })

  it("detects 'free admission'", () => {
    expect(extractPrice("Event — Free Admission for kids")).toEqual({
      price: null,
      isFree: true,
    })
  })

  it("detects complimentary", () => {
    expect(extractPrice("Complimentary snacks provided")).toEqual({
      price: null,
      isFree: true,
    })
  })

  it("extracts integer dollar amounts", () => {
    expect(extractPrice("Tickets: $25")).toEqual({ price: 25, isFree: false })
  })

  it("extracts decimal dollar amounts", () => {
    expect(extractPrice("Cost $12.50")).toEqual({ price: 12.5, isFree: false })
  })

  it("returns null price when no info present", () => {
    expect(extractPrice("See website for details")).toEqual({ price: null, isFree: false })
  })

  it("free patterns beat dollar-sign patterns", () => {
    expect(extractPrice("Free event, $5 suggested donation")).toEqual({
      price: null,
      isFree: true,
    })
  })
})

describe("dedupKey", () => {
  it("produces identical keys for same event across sources", () => {
    const a = dedupKey("Family Yoga", "2026-04-15T10:00:00Z", "city-1")
    const b = dedupKey("Family Yoga", "2026-04-15T10:00:00Z", "city-1")
    expect(a).toBe(b)
  })

  it("normalizes title case and whitespace", () => {
    const a = dedupKey("Family Yoga", "2026-04-15T10:00:00Z", "city-1")
    const b = dedupKey("  family YOGA  ", "2026-04-15T10:00:00Z", "city-1")
    expect(a).toBe(b)
  })

  it("truncates to minute precision", () => {
    // Seconds-level drift between sources should still collide
    const a = dedupKey("Event", "2026-04-15T10:00:00Z", "city-1")
    const b = dedupKey("Event", "2026-04-15T10:00:45Z", "city-1")
    expect(a).toBe(b)
  })

  it("produces different keys for different cities", () => {
    const a = dedupKey("Event", "2026-04-15T10:00:00Z", "city-1")
    const b = dedupKey("Event", "2026-04-15T10:00:00Z", "city-2")
    expect(a).not.toBe(b)
  })

  it("handles null city gracefully", () => {
    expect(dedupKey("Event", "2026-04-15T10:00:00Z", null)).toContain("null::")
  })

  it("produces different keys for different times (minute-level)", () => {
    const a = dedupKey("Event", "2026-04-15T10:00:00Z", "c")
    const b = dedupKey("Event", "2026-04-15T11:00:00Z", "c")
    expect(a).not.toBe(b)
  })
})
