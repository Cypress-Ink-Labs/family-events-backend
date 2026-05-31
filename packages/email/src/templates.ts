export const TEMPLATES = {
  welcome: "family-events-welcome",
  magicLink: "family-events-magic-link",
  eventInvite: "family-events-event-invite",
  eventReminder: "family-events-event-reminder",
  eventChange: "family-events-event-change",
  weeklyDigest: "family-events-weekly-digest",
} as const

export type TemplateAlias = (typeof TEMPLATES)[keyof typeof TEMPLATES]
