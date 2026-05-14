import { describe, expect, it } from "vitest"
import { eventContractSchema } from "./event"

describe("eventContractSchema", () => {
  it("accepts published event shape", () => {
    const parsed = eventContractSchema.parse({
      id: "evt_1",
      title: "Music in the Park",
      start_datetime: "2026-05-14T18:00:00Z",
      end_datetime: null,
      timezone: "America/Chicago",
      city_id: "city_1",
      is_free: true,
      status: "published",
    })
    expect(parsed.status).toBe("published")
  })

  it("rejects unknown status", () => {
    const result = eventContractSchema.safeParse({
      id: "evt_1",
      title: "Bad Status",
      start_datetime: "2026-05-14T18:00:00Z",
      end_datetime: null,
      timezone: "America/Chicago",
      city_id: "city_1",
      is_free: true,
      status: "archived",
    })
    expect(result.success).toBe(false)
  })
})
