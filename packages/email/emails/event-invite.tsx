import {
  Body,
  Button,
  Container,
  Font,
  Head,
  Heading,
  Html,
  Img,
  Preview,
  Section,
  Tailwind,
  Text,
} from "react-email"

/**
 * Event Invite email — "Dusk-Meadow" theme.
 *
 * Mustache-style placeholders replaced at send time:
 *   {{{INVITER_NAME}}}  – name of the person who sent the invite
 *   {{{EVENT_TITLE}}}   – name of the event
 *   {{{EVENT_DATE}}}    – formatted date/time
 *   {{{EVENT_LOCATION}}}– venue or address
 *   {{{EVENT_URL}}}     – link to the event detail page
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

export default function EventInviteEmail() {
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
            url: "https://fonts.gstatic.com/s/fraunces/v36/6NUh8FyLNQOQZAnv9bYEvDiIdE9Ea92uemAk_WBq8U_9v0jzMzwS6Q.woff2",
            format: "woff2",
          }}
          fontWeight={600}
          fontStyle="normal"
        />
      </Head>
      <Preview>
        {"{{{INVITER_NAME}}}"} invited you to {"{{{EVENT_TITLE}}}"}
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
                You're Invited!
              </Heading>
              <Text className="m-0 mt-3.5 inline-block rounded-full border border-white/25 bg-white/[0.16] px-3.5 py-1.5 font-mono text-xs tracking-wide text-white">
                From {"{{{INVITER_NAME}}}"}
              </Text>
            </Section>

            {/* Greeting */}
            <Section className="px-10 pb-1.5 pt-7">
              <Text className="m-0 font-editorial text-[17px] leading-relaxed text-text-muted">
                <span className="font-semibold text-text-primary">{"{{{INVITER_NAME}}}"}</span> thinks
                you'd enjoy this event and wanted to share it with you.
              </Text>
            </Section>

            {/* Event Card */}
            <Section className="px-10 pb-1.5 pt-5">
              <div className="overflow-hidden rounded-xl border border-solid border-border bg-bg">
                <div className="border-b border-solid border-border bg-surface px-5 py-4">
                  <Text className="m-0 font-display text-[19px] font-semibold leading-snug text-text-primary">
                    {"{{{EVENT_TITLE}}}"}
                  </Text>
                </div>
                <div className="px-5 py-4">
                  <table cellPadding={0} cellSpacing={0} role="presentation" className="w-full">
                    <tr>
                      <td className="pb-2">
                        <Text className="m-0 font-mono text-xs uppercase tracking-wider text-text-muted">
                          When
                        </Text>
                        <Text className="m-0 mt-1 font-sans text-[15px] text-text-primary">
                          {"{{{EVENT_DATE}}}"}
                        </Text>
                      </td>
                    </tr>
                    <tr>
                      <td>
                        <Text className="m-0 font-mono text-xs uppercase tracking-wider text-text-muted">
                          Where
                        </Text>
                        <Text className="m-0 mt-1 font-sans text-[15px] text-text-primary">
                          {"{{{EVENT_LOCATION}}}"}
                        </Text>
                      </td>
                    </tr>
                  </table>
                </div>
              </div>
            </Section>

            {/* CTA */}
            <Section className="px-10 pb-9 pt-6 text-center">
              <Button
                href={"{{{EVENT_URL}}}"}
                className="inline-block rounded-full bg-peach px-7 py-3.5 font-sans text-[15px] font-bold text-white"
              >
                View event &rarr;
              </Button>
            </Section>

            {/* Footer */}
            <Section className="border-t border-solid border-border bg-bg px-10 py-6">
              <Text className="m-0 text-center font-sans text-xs leading-relaxed text-text-muted">
                You're receiving this because {"{{{INVITER_NAME}}}"} shared this event with you.
              </Text>
              <Text className="m-0 mt-3.5 text-center font-mono text-[11px] tracking-wide text-text-muted opacity-70">
                FAMILY EVENTS
              </Text>
            </Section>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  )
}
