import { z } from "zod"

export const eventContractSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  start_datetime: z.string().min(1),
  end_datetime: z.string().nullable(),
  timezone: z.string().min(1),
  city_id: z.string().nullable(),
  is_free: z.boolean(),
  status: z.enum(["draft", "review", "published", "rejected"]),
})

export type EventContract = z.infer<typeof eventContractSchema>
