import {
  Body,
  Button,
  Container,
  Font,
  Head,
  Heading,
  Html,
  Img,
  Link,
  Preview,
  Section,
  Tailwind,
  Text,
} from "react-email"

/**
 * Community Event Status email — "Dusk-Meadow" theme.
 *
 * Sent when an admin approves or rejects a community-submitted event.
 *
 * Mustache-style placeholders replaced at send time:
 *   {{{USERNAME}}}      – display name of the submitter
 *   {{{EVENT_TITLE}}}   – name of the event
 *   {{{STATUS}}}        – "approved" or "rejected"
 *   {{{STATUS_MESSAGE}}} – contextual message based on status
 *   {{{EVENT_URL}}}     – link to the event (approved) or submit page (rejected)
 *   {{{CTA_LABEL}}}     – button text
 *   {{{LOGO_URL}}}      – brand logo URL
 *   {{{APP_URL}}}       – base app URL
 */

const tailwindConfig = {
  theme: {
    extend: {
      colors: {
        bg: "#F5F3FC",
        surface: "#FDFCFF",
        "text-primary": "#1C1828",
        "text-muted": "#6B6278",
        border: "#EAE4F6",
        violet: "#7B5CC8",
        "violet-dark": "#5B3DA8",
        success: "#16A34A",
      },
    },
  },
}

export default function CommunityEventStatusEmail() {
  return (
    <Html lang="en" dir="ltr">
      <Head>
        <Font
          fontFamily="DM Sans"
          fallbackFontFamily="Helvetica"
          webFont={{
            url: "https://fonts.gstatic.com/s/dmsans/v15/rP2tp2ywxg089UriI5-g4vlH9VoD8CmcqZG40F9JadbnoEwAop1hTmf3ZGMZpg.woff2",
            format: "woff2",
          }}
          fontWeight={400}
          fontStyle="normal"
        />
      </Head>
      <Preview>Your community event "{`{{{EVENT_TITLE}}}`}" has been {`{{{STATUS}}}`}</Preview>
      <Tailwind config={tailwindConfig}>
        <Body className="bg-bg font-sans">
          <Container className="mx-auto max-w-[520px] py-8">
            {/* Logo */}
            <Section className="text-center mb-6">
              <Img
                src={`{{{LOGO_URL}}}`}
                alt="Family Events"
                width="48"
                height="48"
                className="mx-auto"
              />
            </Section>

            {/* Card */}
            <Section className="bg-surface rounded-2xl border border-border px-8 py-8">
              <Heading className="text-xl font-bold text-text-primary text-center mt-0 mb-2">
                Event {`{{{STATUS}}}`}!
              </Heading>

              <Text className="text-sm text-text-muted text-center mt-0 mb-6">
                Hi {`{{{USERNAME}}}`}, your community event has been reviewed.
              </Text>

              {/* Event title card */}
              <Section className="bg-bg rounded-xl px-5 py-4 mb-6">
                <Text className="text-base font-semibold text-text-primary m-0">
                  {`{{{EVENT_TITLE}}}`}
                </Text>
              </Section>

              <Text className="text-sm text-text-muted leading-relaxed mt-0 mb-6">
                {`{{{STATUS_MESSAGE}}}`}
              </Text>

              {/* CTA */}
              <Section className="text-center">
                <Button
                  href={`{{{EVENT_URL}}}`}
                  className="bg-violet text-white text-sm font-semibold rounded-full px-8 py-3 no-underline"
                >
                  {`{{{CTA_LABEL}}}`}
                </Button>
              </Section>
            </Section>

            {/* Footer */}
            <Text className="text-xs text-text-muted text-center mt-6">
              <Link href={`{{{APP_URL}}}`} className="text-violet no-underline">
                Family Events
              </Link>{" "}
              — curated family-friendly events near you.
            </Text>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  )
}
