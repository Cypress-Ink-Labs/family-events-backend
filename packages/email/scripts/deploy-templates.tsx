import { render } from '@react-email/render'
import { Resend } from 'resend'
import EventInviteEmail from '../emails/event-invite.tsx'
import EventReminderEmail from '../emails/event-reminder.tsx'
import MagicLinkEmail from '../emails/magic-link.tsx'
import WelcomeEmail from '../emails/welcome.tsx'

const apiKey = process.env['RESEND_API_KEY']
if (!apiKey) {
  throw new Error('RESEND_API_KEY environment variable is required')
}

const resend = new Resend(apiKey)

const str = (key: string, fallbackValue?: string) =>
  ({ key, type: 'string' as const, fallbackValue })

const templates = [
  {
    name: 'Family Events – Welcome',
    alias: 'family-events-welcome',
    subject: 'Welcome to Family Events',
    react: <WelcomeEmail />,
    variables: [
      str('USERNAME', 'there'),
      str('APP_URL', 'https://familyevents.app'),
    ],
  },
  {
    name: 'Family Events – Magic Link',
    alias: 'family-events-magic-link',
    subject: 'Your Family Events sign-in link',
    react: <MagicLinkEmail />,
    variables: [
      str('USERNAME', 'there'),
      str('MAGIC_LINK', 'https://familyevents.app/auth'),
      str('EXPIRES_IN', '15 minutes'),
    ],
  },
  {
    name: 'Family Events – Event Invite',
    alias: 'family-events-event-invite',
    subject: '{{{INVITER_NAME}}} invited you to {{{EVENT_TITLE}}}',
    react: <EventInviteEmail />,
    variables: [
      str('INVITER_NAME', 'Someone'),
      str('EVENT_TITLE', 'an event'),
      str('EVENT_DATE'),
      str('EVENT_LOCATION'),
      str('EVENT_URL', 'https://familyevents.app/events'),
    ],
  },
  {
    name: 'Family Events – Event Reminder',
    alias: 'family-events-event-reminder',
    subject: 'Reminder: {{{EVENT_TITLE}}} is coming up',
    react: <EventReminderEmail />,
    variables: [
      str('USERNAME', 'there'),
      str('EVENT_TITLE', 'your event'),
      str('EVENT_DATE'),
      str('EVENT_LOCATION'),
      str('EVENT_URL', 'https://familyevents.app/events'),
    ],
  },
]

for (const template of templates) {
  console.log(`Deploying template: ${template.name}`)
  const { react, ...rest } = template
  const html = await render(react)
  const result = await resend.templates.create({ ...rest, html }).publish()
  console.log(`  Created template id: ${result.data?.id ?? 'unknown'}`)
}

console.log('All templates deployed.')
