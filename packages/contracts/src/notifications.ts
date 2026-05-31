import type { Tables } from "./database.types"

// ─── Enums ──────────────────────────────────────────────────────────────────

export const NOTIFICATION_TYPES = ["reminder", "change", "digest", "system"] as const
export type NotificationType = (typeof NOTIFICATION_TYPES)[number]

export const PUSH_PLATFORMS = ["web", "ios", "android"] as const
export type PushPlatform = (typeof PUSH_PLATFORMS)[number]

// ─── Row types ──────────────────────────────────────────────────────────────

export type UserNotificationRow = Tables<"user_notifications">
export type PushSubscriptionRow = Tables<"push_subscriptions">

// ─── Domain types ───────────────────────────────────────────────────────────

/** User-facing notification item for the notification center. */
export interface UserNotification {
  id: string
  type: NotificationType
  title: string
  body: string
  event_id: string | null
  read_at: string | null
  created_at: string
}

/** Push subscription record. */
export interface PushSubscription {
  id: string
  user_id: string
  platform: PushPlatform
  endpoint: string | null
  token: string | null
  p256dh: string | null
  auth_key: string | null
  created_at: string
  updated_at: string
}

// ─── RPC parameter types ────────────────────────────────────────────────────

export interface MarkNotificationReadParams {
  p_notification_id: string
}

export interface RegisterPushSubscriptionParams {
  p_platform: PushPlatform
  p_endpoint?: string | null
  p_token?: string | null
  p_p256dh?: string | null
  p_auth_key?: string | null
}

export interface UnregisterPushSubscriptionParams {
  p_subscription_id: string
}
