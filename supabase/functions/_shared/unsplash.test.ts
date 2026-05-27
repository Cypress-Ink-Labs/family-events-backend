import { describe, expect, it, vi } from "vitest"
import { deriveTitleSearchTerm, findFallbackImage, trackUnsplashDownload } from "./unsplash"

function mockFetch(impl: typeof fetch) {
  return impl as unknown as typeof fetch
}

function jsonResponse(body: unknown, init: ResponseInit = { status: 200 }): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
  })
}

function unsplashHit(overrides: Record<string, unknown> = {}) {
  return {
    id: "abc",
    urls: { regular: "https://images.unsplash.com/photo-museum.jpg" },
    links: {
      html: "https://unsplash.com/photos/abc",
      download_location: "https://api.unsplash.com/photos/abc/download",
    },
    user: {
      name: "Jane Doe",
      username: "jane",
      links: { html: "https://unsplash.com/@jane" },
    },
    ...overrides,
  }
}

// ---------------------------------------------------------------------------
// deriveTitleSearchTerm
// ---------------------------------------------------------------------------

describe("deriveTitleSearchTerm", () => {
  it("returns null for an empty string", () => {
    expect(deriveTitleSearchTerm("")).toBeNull()
  })

  it("returns null for a very short string after normalization", () => {
    expect(deriveTitleSearchTerm("Hi")).toBeNull()
  })

  it("strips 'at <Venue>' suffix", () => {
    expect(deriveTitleSearchTerm("Splash Park at East Side Recreation Center")).toBe("splash park")
  })

  it("strips 'presented by …' suffix", () => {
    expect(deriveTitleSearchTerm("Summer Reading presented by BREC")).toBe("summer reading")
  })

  it("strips 'hosted by …' suffix", () => {
    expect(deriveTitleSearchTerm("Storytime hosted by the Library")).toBe("storytime")
  })

  it("strips 'sponsored by …' suffix", () => {
    expect(deriveTitleSearchTerm("Craft Fair sponsored by Arts Council")).toBe("craft fair")
  })

  it("takes up to 4 words", () => {
    expect(deriveTitleSearchTerm("Thanksgiving Story Time for Families")).toBe(
      "thanksgiving story time for"
    )
  })

  it("strips punctuation", () => {
    expect(deriveTitleSearchTerm("Art & Crafts! Workshop")).toBe("art crafts workshop")
  })

  it("lowercases output", () => {
    expect(deriveTitleSearchTerm("Splash Park")).toBe("splash park")
  })

  it("handles a plain short title without a venue suffix", () => {
    expect(deriveTitleSearchTerm("Community Day")).toBe("community day")
  })
})

// ---------------------------------------------------------------------------
// findFallbackImage
// ---------------------------------------------------------------------------

describe("findFallbackImage", () => {
  it("returns null when access key is missing", async () => {
    const fetchSpy = vi.fn()
    const result = await findFallbackImage(["museum"], "", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("returns null when tag list is empty and no title supplied", async () => {
    const fetchSpy = vi.fn()
    const result = await findFallbackImage([], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("uses the title-derived term before tag slugs", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [unsplashHit()] }))
    const result = await findFallbackImage(["sports"], "key", {
      fetchImpl: mockFetch(fetchSpy),
      title: "Splash Park at East Side Recreation Center",
    })
    expect(result?.matchedTag).toBe("splash park")
    const firstCall = fetchSpy.mock.calls[0]?.[0] as string
    // Two-pass: tries bare term first
    expect(firstCall).toContain("query=splash%20park")
    expect(firstCall).not.toContain("family")
    // Only one fetch — bare term succeeded immediately, no suffix fallback needed
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("falls through to tag slugs when title query returns no results", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      // Two-pass for title: bare first, then suffix
      if (target.includes("query=splash%20park") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=splash%20park%20family")) {
        return jsonResponse({ results: [] })
      }
      // Two-pass for first tag: bare first, then suffix
      if (target.includes("query=sports") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=sports%20family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/sports.jpg" } })],
        })
      }
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["sports"], "key", {
      fetchImpl: mockFetch(fetchSpy),
      title: "Splash Park",
    })
    expect(result?.url).toBe("https://images.unsplash.com/sports.jpg")
    // matchedTag reflects the actual query that succeeded (with suffix)
    expect(result?.matchedTag).toBe("sports family")
    // 4 fetches: title bare, title suffix, sports bare, sports suffix
    expect(fetchSpy).toHaveBeenCalledTimes(4)
  })

  it("hits the search endpoint and returns image plus attribution metadata", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [unsplashHit()] }))
    const result = await findFallbackImage(["museum", "art"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toEqual({
      url: "https://images.unsplash.com/photo-museum.jpg",
      matchedTag: "museum",
      attribution: {
        photoId: "abc",
        photographerName: "Jane Doe",
        photographerUsername: "jane",
        photographerProfileUrl: "https://unsplash.com/@jane",
        photoUrl: "https://unsplash.com/photos/abc",
        downloadLocation: "https://api.unsplash.com/photos/abc/download",
      },
    })
    const firstCall = fetchSpy.mock.calls[0]?.[0] as string
    // Two-pass: tries bare term first
    expect(firstCall).toContain("query=museum")
    expect(firstCall).not.toContain("family")
    expect(firstCall).toContain("orientation=landscape")
    expect(firstCall).toContain("per_page=5")
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("does not fire-and-forget the download tracking endpoint", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [unsplashHit()] }))
    await findFallbackImage(["concert"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect((fetchSpy.mock.calls[0]?.[0] as string).includes("/search/photos")).toBe(true)
  })

  it("skips hits missing required attribution metadata", async () => {
    const fetchSpy = vi.fn(async () =>
      jsonResponse({
        results: [unsplashHit({ links: { html: "https://unsplash.com/photos/abc" } })],
      })
    )
    const result = await findFallbackImage(["museum"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
  })

  it("falls through to the next tag when the first one yields no results", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      // Two-pass for obscure: bare first, then suffix
      if (target.includes("query=obscure") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=obscure%20family")) {
        return jsonResponse({ results: [] })
      }
      // Two-pass for park: bare first, then suffix
      if (target.includes("query=park") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=park%20family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/park.jpg" } })],
        })
      }
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["obscure", "park"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/park.jpg")
    // matchedTag reflects the actual query that succeeded (with suffix)
    expect(result?.matchedTag).toBe("park family")
  })

  it("returns null when every candidate misses", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [] }))
    const result = await findFallbackImage(["a", "b", "c"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
  })

  it("treats non-2xx as a miss and tries the next candidate", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=rate%20family")) {
        return new Response("rate limited", { status: 429 })
      }
      if (target.includes("query=art%20family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/art.jpg" } })],
        })
      }
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["rate", "art"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/art.jpg")
  })

  it("swallows network errors and tries the next candidate", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=broken%20family")) {
        throw new Error("network down")
      }
      return jsonResponse({
        results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/ok.jpg" } })],
      })
    })
    const result = await findFallbackImage(["broken", "ok"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/ok.jpg")
  })

  it("ignores blank tag entries", async () => {
    const fetchSpy = vi.fn(async () =>
      jsonResponse({
        results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/y.jpg" } })],
      })
    )
    const result = await findFallbackImage(["", "   ", "library"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.matchedTag).toBe("library")
    const firstCall = fetchSpy.mock.calls[0]?.[0] as string
    // Two-pass: tries bare term first
    expect(firstCall).toContain("query=library")
    expect(firstCall).not.toContain("family")
  })

  it("picks randomly among multiple results", async () => {
    // Seed Math.random to return 0.9 → picks the last result out of 3
    const randomSpy = vi.spyOn(Math, "random").mockReturnValue(0.9)
    const results = [
      unsplashHit({ id: "r0", urls: { regular: "https://images.unsplash.com/r0.jpg" } }),
      unsplashHit({ id: "r1", urls: { regular: "https://images.unsplash.com/r1.jpg" } }),
      unsplashHit({
        id: "r2",
        urls: { regular: "https://images.unsplash.com/r2.jpg" },
        links: {
          html: "https://unsplash.com/photos/r2",
          download_location: "https://api.unsplash.com/photos/r2/download",
        },
      }),
    ]
    const fetchSpy = vi.fn(async () => jsonResponse({ results }))
    const result = await findFallbackImage(["art"], "key", { fetchImpl: mockFetch(fetchSpy) })
    // Math.floor(0.9 * 3) = 2 → picks index 2
    expect(result?.url).toBe("https://images.unsplash.com/r2.jpg")
    randomSpy.mockRestore()
  })

  // Two-pass behavior tests
  it("uses bare term when it returns results (no suffix needed)", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=yoga") && !target.includes("family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/yoga.jpg" } })],
        })
      }
      // Should never reach the suffix query
      return jsonResponse({ results: [] })
    })
    const result = await findFallbackImage(["yoga"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/yoga.jpg")
    expect(result?.matchedTag).toBe("yoga")
    // Only one fetch — bare term succeeded immediately
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("falls back to suffix when bare term returns empty", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=cooking") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=cooking%20family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/cooking.jpg" } })],
        })
      }
      return jsonResponse({ results: [] })
    })
    const result = await findFallbackImage(["cooking"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/cooking.jpg")
    expect(result?.matchedTag).toBe("cooking family")
    // Two fetches — bare miss, suffix hit
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it("returns null when both bare and suffixed queries return empty", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [] }))
    const result = await findFallbackImage(["obscure-niche-term"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
    // Two fetches — bare miss, suffix miss
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })

  it("matchedTag reflects the term that actually succeeded (bare vs suffixed)", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      // First term: bare succeeds
      if (target.includes("query=sports") && !target.includes("family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/sports.jpg" } })],
        })
      }
      return jsonResponse({ results: [] })
    })
    const result = await findFallbackImage(["sports"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.matchedTag).toBe("sports")

    // Second scenario: suffix succeeds
    const fetchSpy2 = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=picnic") && !target.includes("family")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=picnic%20family")) {
        return jsonResponse({
          results: [unsplashHit({ urls: { regular: "https://images.unsplash.com/picnic.jpg" } })],
        })
      }
      return jsonResponse({ results: [] })
    })
    const result2 = await findFallbackImage(["picnic"], "key", { fetchImpl: mockFetch(fetchSpy2) })
    expect(result2?.matchedTag).toBe("picnic family")
  })
})

// ---------------------------------------------------------------------------
// trackUnsplashDownload
// ---------------------------------------------------------------------------

describe("trackUnsplashDownload", () => {
  it("awaits the download tracking endpoint and returns success", async () => {
    const fetchSpy = vi.fn(async () => new Response(null, { status: 200 }))
    const result = await trackUnsplashDownload("https://api.unsplash.com/photos/abc/download", "key", {
      fetchImpl: mockFetch(fetchSpy),
    })

    expect(result).toEqual({ ok: true, error: null })
    expect(fetchSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy.mock.calls[0]?.[1]).toMatchObject({
      headers: { Authorization: "Client-ID key", "Accept-Version": "v1" },
    })
  })

  it("returns a failure result for HTTP errors", async () => {
    const fetchSpy = vi.fn(async () => new Response("rate limited", { status: 429 }))
    const result = await trackUnsplashDownload("https://api.unsplash.com/photos/abc/download", "key", {
      fetchImpl: mockFetch(fetchSpy),
    })
    expect(result.ok).toBe(false)
    expect(result.error).toContain("HTTP 429")
  })

  it("returns a failure result for network errors", async () => {
    const fetchSpy = vi.fn(async () => {
      throw new Error("network down")
    })
    const result = await trackUnsplashDownload("https://api.unsplash.com/photos/abc/download", "key", {
      fetchImpl: mockFetch(fetchSpy),
    })
    expect(result).toEqual({ ok: false, error: "network down" })
  })
})
