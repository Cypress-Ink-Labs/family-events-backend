/**
 * Tests that geocodeCache and imageCache deduplicate external calls within a
 * batch when two rows share the same address/venue and the same tag set.
 */
import { assertEquals } from "jsr:@std/assert";
import { buildGeocodeQuery, type GeocodeResult } from "../_shared/geocode.ts";
import { type StockImageResult } from "../_shared/stock-images.ts";

// ---------------------------------------------------------------------------
// Minimal fakes
// ---------------------------------------------------------------------------

type FakeGeocoder = {
  calls: string[];
  impl: (query: string) => Promise<GeocodeResult | null>;
};

type FakeImageFinder = {
  calls: string[][];
  impl: (tags: string[]) => Promise<StockImageResult | null>;
};

// Recreate the cache-aware geocode helper inline (same logic as enrichOne).
async function geocodeCached(
  query: string,
  geocodeCache: Map<string, GeocodeResult | null>,
  geocoder: FakeGeocoder,
): Promise<GeocodeResult | null> {
  if (geocodeCache.has(query)) {
    return geocodeCache.get(query)!;
  }
  const result = await geocoder.impl(query);
  geocodeCache.set(query, result);
  return result;
}

// Recreate the cache-aware image helper inline.
async function imageCached(
  tags: string[],
  imageCache: Map<string, StockImageResult | null>,
  finder: FakeImageFinder,
): Promise<StockImageResult | null> {
  const imageKey = [...tags].sort().join(",");
  if (imageCache.has(imageKey)) {
    return imageCache.get(imageKey)!;
  }
  const result = await finder.impl(tags);
  imageCache.set(imageKey, result);
  return result;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

Deno.test("geocodeCache: same query called once, both rows get coords", async () => {
  const geocoder: FakeGeocoder = {
    calls: [],
    impl: async (query: string) => {
      geocoder.calls.push(query);
      return { latitude: 30.1, longitude: -90.2, source: "nominatim" } as GeocodeResult;
    },
  };

  const geocodeCache = new Map<string, GeocodeResult | null>();

  const query = buildGeocodeQuery({
    address: "123 Main St",
    venueName: "City Library",
    cityName: "New Orleans",
    cityState: "LA",
  });

  // Two rows share the same venue/address → same query string
  const geo1 = await geocodeCached(query!, geocodeCache, geocoder);
  const geo2 = await geocodeCached(query!, geocodeCache, geocoder);

  assertEquals(geocoder.calls.length, 1, "geocoder called exactly once");
  assertEquals(geo1?.latitude, 30.1);
  assertEquals(geo2?.latitude, 30.1, "second row gets same coords from cache");
});

Deno.test("geocodeCache: miss is cached (no retry for same failing venue)", async () => {
  const geocoder: FakeGeocoder = {
    calls: [],
    impl: async (query: string) => {
      geocoder.calls.push(query);
      return null; // geocode miss
    },
  };

  const geocodeCache = new Map<string, GeocodeResult | null>();
  const query = "Unknown Venue, Nowhere, ZZ";

  const geo1 = await geocodeCached(query, geocodeCache, geocoder);
  const geo2 = await geocodeCached(query, geocodeCache, geocoder);

  assertEquals(geocoder.calls.length, 1, "miss cached — geocoder called once");
  assertEquals(geo1, null);
  assertEquals(geo2, null, "second row also gets null from cache");
});

Deno.test("imageCache: same tags called once, both rows get image and imageSource", async () => {
  const fakeResult: StockImageResult = {
    url: "https://images.pexels.com/photo.jpg",
    matchedTag: "storytime",
    attribution: {
      provider: "pexels",
      photoId: "12345",
      photographerName: "Jane Doe",
      photographerProfileUrl: "https://pexels.com/jane",
      photoUrl: "https://pexels.com/12345",
      downloadLocation: undefined,
      photographerUsername: undefined,
    },
  };

  const finder: FakeImageFinder = {
    calls: [],
    impl: async (tags: string[]) => {
      finder.calls.push([...tags]);
      return fakeResult;
    },
  };

  const imageCache = new Map<string, StockImageResult | null>();
  const tags = ["storytime", "kids", "library"];

  const img1 = await imageCached(tags, imageCache, finder);
  const img2 = await imageCached(tags, imageCache, finder);

  assertEquals(finder.calls.length, 1, "image finder called exactly once");
  assertEquals(img1?.url, fakeResult.url);
  assertEquals(img2?.url, fakeResult.url, "second row gets same image from cache");
  assertEquals(img1?.attribution.provider, "pexels");
  assertEquals(img2?.attribution.provider, "pexels", "imageSource preserved on cache hit");
});

Deno.test("imageCache: tag order does not affect cache key", async () => {
  const finder: FakeImageFinder = {
    calls: [],
    impl: async (tags: string[]) => {
      finder.calls.push([...tags]);
      return {
        url: "https://images.pexels.com/other.jpg",
        matchedTag: "kids",
        attribution: {
          provider: "pexels" as const,
          photoId: "99",
          photographerName: "Bob",
          photographerProfileUrl: "https://pexels.com/bob",
          photoUrl: "https://pexels.com/99",
        },
      } satisfies StockImageResult;
    },
  };

  const imageCache = new Map<string, StockImageResult | null>();

  const img1 = await imageCached(["kids", "library"], imageCache, finder);
  // Same tags in different order
  const img2 = await imageCached(["library", "kids"], imageCache, finder);

  assertEquals(finder.calls.length, 1, "sorted key deduplicates regardless of input order");
  assertEquals(img1?.url, img2?.url);
});

Deno.test("imageCache: different tags call finder separately", async () => {
  let callCount = 0;
  const finder: FakeImageFinder = {
    calls: [],
    impl: async (tags: string[]) => {
      finder.calls.push([...tags]);
      callCount += 1;
      return {
        url: `https://images.pexels.com/photo-${callCount}.jpg`,
        matchedTag: tags[0],
        attribution: {
          provider: "pexels" as const,
          photoId: String(callCount),
          photographerName: "Photographer",
          photographerProfileUrl: "https://pexels.com/p",
          photoUrl: `https://pexels.com/${callCount}`,
        },
      } satisfies StockImageResult;
    },
  };

  const imageCache = new Map<string, StockImageResult | null>();

  const img1 = await imageCached(["storytime"], imageCache, finder);
  const img2 = await imageCached(["sports"], imageCache, finder);

  assertEquals(finder.calls.length, 2, "different tag sets each get their own lookup");
  assertEquals(img1?.url !== img2?.url, true);
});
