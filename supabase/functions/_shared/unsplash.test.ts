import { describe, expect, it, vi } from "vitest"
import { findFallbackImage } from "./unsplash"

function mockFetch(impl: typeof fetch) {
  return impl as unknown as typeof fetch
}

function jsonResponse(body: unknown, init: ResponseInit = { status: 200 }): Response {
  return new Response(JSON.stringify(body), {
    ...init,
    headers: { "Content-Type": "application/json", ...(init.headers ?? {}) },
  })
}

describe("findFallbackImage", () => {
  it("returns null when access key is missing", async () => {
    const fetchSpy = vi.fn()
    const result = await findFallbackImage(["museum"], "", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("returns null when tag list is empty", async () => {
    const fetchSpy = vi.fn()
    const result = await findFallbackImage([], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("hits the search endpoint with the first tag and returns the regular URL", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("/search/photos")) {
        return jsonResponse({
          results: [
            {
              urls: { regular: "https://images.unsplash.com/photo-museum.jpg" },
              links: { download_location: "https://api.unsplash.com/photos/abc/download" },
            },
          ],
        })
      }
      // Tracking ping
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["museum", "art"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toEqual({
      url: "https://images.unsplash.com/photo-museum.jpg",
      matchedTag: "museum",
    })
    const firstCall = fetchSpy.mock.calls[0]?.[0] as string
    expect(firstCall).toContain("query=museum%20family")
    expect(firstCall).toContain("orientation=landscape")
    expect(firstCall).toContain("per_page=1")
  })

  it("triggers the download tracking endpoint when present", async () => {
    const calls: string[] = []
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      calls.push(target)
      if (target.includes("/search/photos")) {
        return jsonResponse({
          results: [
            {
              urls: { regular: "https://images.unsplash.com/x.jpg" },
              links: { download_location: "https://api.unsplash.com/photos/x/download" },
            },
          ],
        })
      }
      return new Response(null, { status: 200 })
    })
    await findFallbackImage(["concert"], "key", { fetchImpl: mockFetch(fetchSpy) })
    // Allow the fire-and-forget tracking ping to run.
    await new Promise((resolve) => setTimeout(resolve, 5))
    expect(calls.some((c) => c.includes("/photos/x/download"))).toBe(true)
  })

  it("falls through to the next tag when the first one yields no results", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=obscure")) {
        return jsonResponse({ results: [] })
      }
      if (target.includes("query=park")) {
        return jsonResponse({
          results: [
            { urls: { regular: "https://images.unsplash.com/park.jpg" }, links: {} },
          ],
        })
      }
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["obscure", "park"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/park.jpg")
    expect(result?.matchedTag).toBe("park")
  })

  it("returns null when every tag misses", async () => {
    const fetchSpy = vi.fn(async () => jsonResponse({ results: [] }))
    const result = await findFallbackImage(["a", "b", "c"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result).toBeNull()
  })

  it("treats non-2xx as a miss and tries the next tag", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=rate")) {
        return new Response("rate limited", { status: 429 })
      }
      if (target.includes("query=art")) {
        return jsonResponse({
          results: [{ urls: { regular: "https://images.unsplash.com/art.jpg" }, links: {} }],
        })
      }
      return new Response(null, { status: 200 })
    })
    const result = await findFallbackImage(["rate", "art"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/art.jpg")
  })

  it("swallows network errors and tries the next tag", async () => {
    const fetchSpy = vi.fn(async (url: string | URL) => {
      const target = url.toString()
      if (target.includes("query=broken")) {
        throw new Error("network down")
      }
      return jsonResponse({
        results: [{ urls: { regular: "https://images.unsplash.com/ok.jpg" }, links: {} }],
      })
    })
    const result = await findFallbackImage(["broken", "ok"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.url).toBe("https://images.unsplash.com/ok.jpg")
  })

  it("ignores blank tag entries", async () => {
    const fetchSpy = vi.fn(async () =>
      jsonResponse({
        results: [{ urls: { regular: "https://images.unsplash.com/y.jpg" }, links: {} }],
      })
    )
    const result = await findFallbackImage(["", "   ", "library"], "key", { fetchImpl: mockFetch(fetchSpy) })
    expect(result?.matchedTag).toBe("library")
    const firstCall = fetchSpy.mock.calls[0]?.[0] as string
    expect(firstCall).toContain("query=library%20family")
  })
})
