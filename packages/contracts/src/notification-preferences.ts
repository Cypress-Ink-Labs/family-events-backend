import type { Tables } from "./database.types"

/**
 * Row type for user_notification_preferences table.
 */
export type NotificationPreferencesRow = Tables<"user_notification_preferences">

/**
 * Shape of preference toggles (no DB metadata like id, user_id, timestamps).
 */
export interface NotificationPreferences {
  reminder_email: boolean
  reminder_push: boolean
  change_email: boolean
  change_push: boolean
  digest_email: boolean
  digest_push: boolean
}

/**
 * Preference toggle field names, useful for iteration.
 */
export const NOTIFICATION_PREFERENCE_FIELDS = [
  "reminder_email",
  "reminder_push",
  "change_email",
  "change_push",
  "digest_email",
  "digest_push",
] as const satisfies readonly (keyof NotificationPreferences)[]

/**
 * Default preferences for a user who has never saved preferences.
 * Matches the DB column defaults in the migration.
 */
export const DEFAULT_NOTIFICATION_PREFERENCES: Readonly<NotificationPreferences> = {
  reminder_email: true,
  reminder_push: true,
  change_email: true,
  change_push: true,
  digest_email: true,
  digest_push: false,
} as const

/**
 * Parameter shape for the upsert_notification_preferences RPC.
 * Matches the generated Args type with the p_ prefix convention.
 */
export interface UpsertNotificationPreferencesParams {
  p_reminder_email: boolean
  p_reminder_push: boolean
  p_change_email: boolean
  p_change_push: boolean
  p_digest_email: boolean
  p_digest_push: boolean
}

/**
 * Convert app-level preferences to RPC parameters.
 */
export function toUpsertParams(
  prefs: NotificationPreferences
): UpsertNotificationPreferencesParams {
  return {
    p_reminder_email: prefs.reminder_email,
    p_reminder_push: prefs.reminder_push,
    p_change_email: prefs.change_email,
    p_change_push: prefs.change_push,
    p_digest_email: prefs.digest_email,
    p_digest_push: prefs.digest_push,
  }
}
