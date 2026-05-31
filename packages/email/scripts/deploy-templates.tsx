import { render } from "@react-email/render"
import { Resend } from "resend"
import EventChangeEmail from "../emails/event-change.tsx"
import EventInviteEmail from "../emails/event-invite.tsx"
import EventReminderEmail from "../emails/event-reminder.tsx"
import MagicLinkEmail from "../emails/magic-link.tsx"
import WeeklyDigestEmail from "../emails/weekly-digest.tsx"
import WelcomeEmail from "../emails/welcome.tsx"

const apiKey = process.env["RESEND_API_KEY"]
if (!apiKey) {
  throw new Error("RESEND_API_KEY environment variable is required")
}

const resend = new Resend(apiKey)

const str = (key: string, fallbackValue?: string) => ({
  key,
  type: "string" as const,
  fallbackValue,
})

const templates = [
  {
    name: "Family Events – Welcome",
    alias: "family-events-welcome",
    subject: "Welcome to Family Events",
    react: <WelcomeEmail />,
    variables: [
      str("USERNAME", "there"),
      str("APP_URL", "https://familyevents.app"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
    ],
  },
  {
    name: "Family Events – Magic Link",
    alias: "family-events-magic-link",
    subject: "Your Family Events sign-in link",
    react: <MagicLinkEmail />,
    variables: [
      str("USERNAME", "there"),
      str("MAGIC_LINK", "https://familyevents.app/auth"),
      str("EXPIRES_IN", "15 minutes"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
    ],
  },
  {
    name: "Family Events – Event Invite",
    alias: "family-events-event-invite",
    subject: "{{{INVITER_NAME}}} invited you to {{{EVENT_TITLE}}}",
    react: <EventInviteEmail />,
    variables: [
      str("INVITER_NAME", "Someone"),
      str("EVENT_TITLE", "an event"),
      str("EVENT_DATE"),
      str("EVENT_LOCATION"),
      str("EVENT_URL", "https://familyevents.app/events"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
      str("APP_URL", "https://familyevents.app"),
    ],
  },
  {
    name: "Family Events – Event Change",
    alias: "family-events-event-change",
    subject: "Update: {{{EVENT_TITLE}}} has changed",
    react: <EventChangeEmail />,
    variables: [
      str("USERNAME", "there"),
      str("EVENT_TITLE", "your event"),
      str("CHANGE_SUMMARY", "Details have been updated"),
      str("EVENT_DATE"),
      str("EVENT_LOCATION"),
      str("EVENT_URL", "https://familyevents.app/events"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
      str("APP_URL", "https://familyevents.app"),
    ],
  },
  {
    name: "Family Events – Event Reminder",
    alias: "family-events-event-reminder",
    subject: "Reminder: {{{EVENT_TITLE}}} is coming up",
    react: <EventReminderEmail />,
    variables: [
      str("USERNAME", "there"),
      str("EVENT_TITLE", "your event"),
      str("EVENT_DATE"),
      str("EVENT_LOCATION"),
      str("EVENT_URL", "https://familyevents.app/events"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
      str("APP_URL", "https://familyevents.app"),
    ],
  },
  {
    name: "Family Events – Weekly Digest",
    alias: "family-events-weekly-digest",
    subject: "{{{EVENT_COUNT}}} family events this week in {{{CITY_NAME}}}",
    react: <WeeklyDigestEmail />,
    variables: [
      str("USERNAME", "there"),
      str("CITY_NAME", "your city"),
      str("EVENT_COUNT", "0"),
      str("EVENTS_HTML", ""),
      str("APP_URL", "https://familyevents.app"),
      str("LOGO_URL", "https://familyevents.app/brand/family-events-logo.png"),
      str("UNSUBSCRIBE_URL", "https://familyevents.app/profile?tab=notifications"),
    ],
  },
]

for (const template of templates) {
  console.log(`Deploying template: ${template.name}`)
  // Build the create payload explicitly. resend@6.x's Templates.performCreate
  // checks `if (payload.react)` and then calls a `renderAsync` it pulls from
  // `@react-email/render`. v2.x of that package only exports `render`, not
  // `renderAsync`, so any payload that still carries the JSX field crashes
  // with "this.renderAsync is not a function" even when we passed pre-rendered
  // HTML. Strip `react` out and pass html directly to keep that branch dormant.
  const html = await render(template.react)
  const result = await resend.templates
    .create({
      name: template.name,
      alias: template.alias,
      subject: template.subject,
      variables: template.variables,
      html,
    })
    .publish()
  console.log(`  Created template id: ${result.data?.id ?? "unknown"}`)
}

console.log("All templates deployed.")
