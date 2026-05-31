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
 * Welcome email — "Dusk-Meadow" theme.
 *
 * Mustache-style placeholders replaced at send time:
 *   {{{USERNAME}}} – display name of the new user
 *   {{{APP_URL}}}  – base app URL
 *   {{{LOGO_URL}}} – brand logo URL
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

export default function WelcomeEmail() {
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
      <Preview>Welcome to Family Events — discover local activities for your family</Preview>
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
                Welcome!
              </Heading>
              <Text className="m-0 mt-3.5 inline-block rounded-full border border-white/25 bg-white/[0.16] px-3.5 py-1.5 font-mono text-xs tracking-wide text-white">
                Your weekend just got easier
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
                We're so glad you're here. Family Events helps you discover family-friendly
                activities in your neighborhood — from park events and library programs to local
                festivals and kids' workshops.
              </Text>
            </Section>

            {/* Features */}
            <Section className="px-10 pb-1.5 pt-5">
              <div className="overflow-hidden rounded-xl border border-solid border-border bg-bg">
                <div className="border-b border-solid border-border px-5 py-3">
                  <Text className="m-0 font-mono text-xs uppercase tracking-wider text-text-muted">
                    What you can do
                  </Text>
                </div>
                <div className="px-5 py-4">
                  <table cellPadding={0} cellSpacing={0} role="presentation" className="w-full">
                    <tr>
                      <td className="pb-3">
                        <Text className="m-0 font-sans text-[15px] text-text-primary">
                          <strong>Browse events</strong> — Filter by age, cost, and distance
                        </Text>
                      </td>
                    </tr>
                    <tr>
                      <td className="pb-3">
                        <Text className="m-0 font-sans text-[15px] text-text-primary">
                          <strong>Save favorites</strong> — Build a list for the weekend
                        </Text>
                      </td>
                    </tr>
                    <tr>
                      <td>
                        <Text className="m-0 font-sans text-[15px] text-text-primary">
                          <strong>Get reminders</strong> — Never miss an event you saved
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
                href={"{{{APP_URL}}}"}
                className="inline-block rounded-full bg-peach px-7 py-3.5 font-sans text-[15px] font-bold text-white"
              >
                Start exploring &rarr;
              </Button>
            </Section>

            {/* Footer */}
            <Section className="border-t border-solid border-border bg-bg px-10 py-6">
              <Text className="m-0 text-center font-sans text-xs leading-relaxed text-text-muted">
                You're receiving this because you signed up for Family Events.{" "}
                <Link href={"{{{APP_URL}}}/settings/notifications"} className="font-medium text-violet-deep underline">
                  Manage preferences
                </Link>
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
