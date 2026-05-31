import {
  Body,
  Container,
  Head,
  Heading,
  Hr,
  Html,
  Link,
  Preview,
  Section,
  Text,
} from "react-email"

/**
 * Weekly Digest email template.
 *
 * Mustache-style placeholders (triple braces) are replaced at send time by
 * the send-weekly-digest edge function. The template renders a branded header,
 * the user's city, and up to 10 event cards for the upcoming week.
 *
 * Placeholders:
 *   {{{USERNAME}}}    – display name of the recipient
 *   {{{CITY_NAME}}}   – city name (e.g. "Lafayette")
 *   {{{EVENT_COUNT}}} – number of events in the digest
 *   {{{EVENTS_HTML}}} – pre-rendered HTML block of event cards
 *   {{{APP_URL}}}     – base app URL for links
 *   {{{UNSUBSCRIBE_URL}}} – link to notification preferences
 */

export default function WeeklyDigestEmail() {
  return (
    <Html>
      <Head />
      <Preview>
        {"{{{EVENT_COUNT}}}"} family events this week in {"{{{CITY_NAME}}}"}
      </Preview>
      <Body style={body}>
        <Container style={container}>
          {/* Header */}
          <Section style={headerSection}>
            <Text style={headerBrand}>Family Events</Text>
            <Heading style={headerTitle}>Your Weekly Digest</Heading>
            <Text style={headerSubtitle}>
              {"{{{EVENT_COUNT}}}"} events this week in{" "}
              {"{{{CITY_NAME}}}"}
            </Text>
          </Section>

          <Hr style={divider} />

          {/* Greeting */}
          <Text style={greeting}>
            Hi {"{{{USERNAME}}}"},
          </Text>
          <Text style={introText}>
            Here are the upcoming family-friendly events near you this week.
          </Text>

          {/* Event cards – injected as pre-rendered HTML */}
          <Section
            dangerouslySetInnerHTML={{ __html: "{{{EVENTS_HTML}}}" }}
          />

          {/* CTA */}
          <Section style={ctaSection}>
            <Link href={"{{{APP_URL}}}"} style={ctaButton}>
              Browse All Events
            </Link>
          </Section>

          <Hr style={divider} />

          {/* Footer */}
          <Text style={footerText}>
            You're receiving this because you have digest emails enabled.{" "}
            <Link href={"{{{UNSUBSCRIBE_URL}}}"} style={footerLink}>
              Manage preferences
            </Link>
          </Text>
        </Container>
      </Body>
    </Html>
  )
}

/* ── Styles ────────────────────────────────────────────────────────────────── */

const body: React.CSSProperties = {
  backgroundColor: "#f6f9fc",
  fontFamily:
    "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, sans-serif",
  margin: 0,
  padding: 0,
}

const container: React.CSSProperties = {
  backgroundColor: "#ffffff",
  padding: "0",
  borderRadius: "8px",
  margin: "40px auto",
  maxWidth: "560px",
  overflow: "hidden",
}

const headerSection: React.CSSProperties = {
  backgroundColor: "#f59e0b",
  padding: "32px 40px 24px",
  textAlign: "center" as const,
}

const headerBrand: React.CSSProperties = {
  fontSize: "13px",
  fontWeight: 700,
  color: "#0f172a",
  textTransform: "uppercase" as const,
  letterSpacing: "0.12em",
  margin: "0 0 8px",
}

const headerTitle: React.CSSProperties = {
  fontSize: "26px",
  fontWeight: 700,
  color: "#0f172a",
  margin: "0 0 6px",
}

const headerSubtitle: React.CSSProperties = {
  fontSize: "15px",
  color: "#422006",
  margin: 0,
}

const divider: React.CSSProperties = {
  borderColor: "#e6e6e6",
  margin: "0",
}

const greeting: React.CSSProperties = {
  fontSize: "16px",
  color: "#1a1a1a",
  padding: "24px 40px 0",
  margin: 0,
}

const introText: React.CSSProperties = {
  fontSize: "15px",
  color: "#475569",
  padding: "8px 40px 16px",
  margin: 0,
}

const ctaSection: React.CSSProperties = {
  textAlign: "center" as const,
  padding: "24px 40px 32px",
}

const ctaButton: React.CSSProperties = {
  backgroundColor: "#f59e0b",
  color: "#0f172a",
  padding: "12px 24px",
  borderRadius: "10px",
  fontSize: "15px",
  fontWeight: 700,
  textDecoration: "none",
  display: "inline-block",
}

const footerText: React.CSSProperties = {
  fontSize: "12px",
  color: "#94a3b8",
  padding: "20px 40px",
  margin: 0,
  textAlign: "center" as const,
}

const footerLink: React.CSSProperties = {
  color: "#64748b",
  textDecoration: "underline",
}
