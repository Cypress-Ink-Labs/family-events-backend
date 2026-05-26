import { assertEquals } from "jsr:@std/assert"
import { buildGeocodeQuery } from "./geocode.ts"

Deno.test("buildGeocodeQuery: address with same city+state as parts does not duplicate", () => {
  const result = buildGeocodeQuery({
    address: "444 Cajundome Blvd, Lafayette, LA, 70506",
    venueName: "Cajundome",
    cityName: "Lafayette",
    cityState: "LA",
  })
  assertEquals(result, "444 Cajundome Blvd, Lafayette, LA, 70506")
})

Deno.test("buildGeocodeQuery: address with different city but inline state is returned unchanged", () => {
  // city_id points to Lafayette but venue is in Broussard — hasInlineState fires
  const result = buildGeocodeQuery({
    address: "701 St. Nazaire, Broussard, LA, 70518",
    venueName: null,
    cityName: "Lafayette",
    cityState: "LA",
  })
  assertEquals(result, "701 St. Nazaire, Broussard, LA, 70518")
})

Deno.test("buildGeocodeQuery: venueName-only with no inline state appends city+state", () => {
  const result = buildGeocodeQuery({
    address: null,
    venueName: "Moncus Park",
    cityName: "Lafayette",
    cityState: "LA",
  })
  assertEquals(result, "Moncus Park, Lafayette, LA")
})

Deno.test("buildGeocodeQuery: null address and null venueName returns null", () => {
  const result = buildGeocodeQuery({
    address: null,
    venueName: null,
    cityName: "Lafayette",
    cityState: "LA",
  })
  assertEquals(result, null)
})

Deno.test("buildGeocodeQuery: address with inline state but null cityName/cityState returned unchanged", () => {
  const result = buildGeocodeQuery({
    address: "123 Main St, Houston, TX, 77001",
    venueName: null,
    cityName: null,
    cityState: null,
  })
  assertEquals(result, "123 Main St, Houston, TX, 77001")
})

Deno.test("buildGeocodeQuery: address with no state and cityName provided appends city", () => {
  const result = buildGeocodeQuery({
    address: "301 W Congress St",
    venueName: null,
    cityName: "Lafayette",
    cityState: null,
  })
  assertEquals(result, "301 W Congress St, Lafayette")
})

Deno.test("buildGeocodeQuery: address ending in ', LA' (no zip) returned unchanged", () => {
  assertEquals(
    buildGeocodeQuery({ address: "123 Main St, Lafayette, LA", venueName: null, cityName: "Lafayette", cityState: "LA" }),
    "123 Main St, Lafayette, LA"
  )
})

Deno.test("buildGeocodeQuery: city in address but no state appends state only", () => {
  assertEquals(
    buildGeocodeQuery({ address: "123 Main, Lafayette", venueName: null, cityName: "Lafayette", cityState: "LA" }),
    "123 Main, Lafayette, LA"
  )
})
