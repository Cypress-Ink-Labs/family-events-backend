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
 * Weekly Digest email template — "Dusk-Meadow" theme.
 *
 * This is the design-system parity twin of the live send path in
 * supabase/functions/send-weekly-digest/index.ts (renderDigestHtml). The edge
 * function posts raw HTML to Resend, so this file is the preview/source-of-truth
 * for the visual shell. Styled with the Tailwind component so classes inline at
 * render time (email-safe). Theme tokens mirror packages/design-system.
 *
 * Mustache-style placeholders (triple braces) are replaced at send time:
 *   {{{USERNAME}}}        – display name of the recipient
 *   {{{CITY_NAME}}}       – city name (e.g. "Lafayette")
 *   {{{EVENT_COUNT}}}     – number of events in the digest
 *   {{{EVENTS_HTML}}}     – pre-rendered HTML block of event cards
 *   {{{APP_URL}}}         – base app URL for links
 *   {{{LOGO_URL}}}        – brand logo URL
 *   {{{UNSUBSCRIBE_URL}}} – link to notification preferences
 */

// Dusk-Meadow tokens (mirrors packages/design-system/tokens/tokens.json)
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
        "violet-deep": "#5E42A6",
        peach: "#E89060",
      },
      fontFamily: {
        sans: ["DM Sans", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ["Fraunces", "ui-serif", "Georgia", "serif"],
        editorial: ["Newsreader", "ui-serif", "Georgia", "serif"],
        mono: ["Geist Mono", "ui-monospace", "SF Mono", "monospace"],
      },
    },
  },
}

export default function WeeklyDigestEmail() {
  return (
    <Html lang="en">
      <Head>
        <Font
          fontFamily="DM Sans"
          fallbackFontFamily="sans-serif"
          webFont={{
            url: "https://fonts.gstatic.com/s/dmsans/v15/rP2Hp2ywxg089UriCZOIHTWEBlw.woff2",
            format: "woff2",
          }}
          fontWeight={400}
          fontStyle="normal"
        />
        <Font
          fontFamily="Fraunces"
          fallbackFontFamily="serif"
          webFont={{
            url:
              "https://fonts.gstatic.com/s/fraunces/v36/6NUh8FyLNQOQZAnv9bYEvDiIdE9Ea92uemAk_WBq8U_9v0jzMzwS6Q.woff2",
            format: "woff2",
          }}
          fontWeight={600}
          fontStyle="normal"
        />
      </Head>
      <Preview>
        {"{{{EVENT_COUNT}}}"} family events this week in {"{{{CITY_NAME}}}"}
      </Preview>
      <Tailwind config={tailwindConfig}>
        <Body className="m-0 bg-bg p-0 font-sans">
          <Container className="mx-auto my-8 w-full max-w-[600px] overflow-hidden rounded-3xl bg-surface shadow-[0_12px_32px_rgba(28,24,40,0.10)]">
            {/* Header */}
            <Section
              className="px-10 pb-8 pt-9"
              style={{
                backgroundColor: "#7B5CC8",
                backgroundImage: "linear-gradient(135deg,#7B5CC8 0%,#5E42A6 100%)",
              }}
            >
              <table cellPadding={0} cellSpacing={0} role="presentation">
                <tr>
                  <td>
                    <Img
                      src={"{{{LOGO_URL}}}"}
                      width="28"
                      height="28"
                      alt=""
                      className="inline-block rounded-md align-middle"
                    />
                    <span className="pl-2.5 align-middle text-[13px] font-bold uppercase tracking-[0.14em] text-[#F2ECFB]">
                      Family Events
                    </span>
                  </td>
                </tr>
              </table>
              <Heading className="m-0 mt-5 font-display text-[34px] font-semibold leading-tight text-white">
                Your Weekly Digest
              </Heading>
              <Text className="m-0 mt-3.5 inline-block rounded-full border border-white/25 bg-white/[0.16] px-3.5 py-1.5 font-mono text-xs tracking-wide text-white">
                {"{{{EVENT_COUNT}}}"} events this week in {"{{{CITY_NAME}}}"}
              </Text>
            </Section>

            {/* Greeting */}
            <Section className="px-10 pb-1.5 pt-7">
              <Heading
                as="h2"
                className="m-0 mb-2 font-display text-[21px] font-semibold text-text-primary"
              >
                Hi {"{{{USERNAME}}}"},
              </Heading>
              <Text className="m-0 font-editorial text-[17px] leading-relaxed text-text-muted">
                Here are the upcoming family-friendly events near you this week — curated for your
                neighborhood and ready to add to the weekend plan.
              </Text>
            </Section>

            {/* Event cards — injected as pre-rendered HTML by the edge function */}
            <Section className="px-10 pb-1.5 pt-5">
              <div dangerouslySetInnerHTML={{ __html: "{{{EVENTS_HTML}}}" }} />
            </Section>

            {/* CTA */}
            <Section className="px-10 pb-9 pt-4 text-center">
              <Button
                href={"{{{APP_URL}}}"}
                className="inline-block rounded-full bg-peach px-7 py-3.5 font-sans text-[15px] font-bold text-white"
              >
                Browse all events &rarr;
              </Button>
            </Section>

            {/* Footer */}
            <Section className="border-t border-solid border-border bg-bg px-10 py-6">
              <Text className="m-0 text-center font-sans text-xs leading-relaxed text-text-muted">
                You're receiving this because you enabled digest emails.{" "}
                <Link href={"{{{UNSUBSCRIBE_URL}}}"} className="font-medium text-violet-deep underline">
                  Manage preferences
                </Link>
              </Text>
              <Text className="m-0 mt-3.5 text-center font-mono text-[11px] tracking-wide text-text-muted opacity-70">
                FAMILY EVENTS · {"{{{CITY_NAME}}}"}
              </Text>
            </Section>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  )
}
