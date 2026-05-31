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
 * Magic Link email — "Dusk-Meadow" theme.
 *
 * Mustache-style placeholders replaced at send time:
 *   {{{USERNAME}}}   – display name of the user
 *   {{{MAGIC_LINK}}} – the passwordless sign-in URL
 *   {{{EXPIRES_IN}}} – human-readable expiration (e.g. "15 minutes")
 *   {{{LOGO_URL}}}   – brand logo URL
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

export default function MagicLinkEmail() {
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
      <Preview>Your Family Events sign-in link</Preview>
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
                Sign In
              </Heading>
              <Text className="m-0 mt-3.5 inline-block rounded-full border border-white/25 bg-white/[0.16] px-3.5 py-1.5 font-mono text-xs tracking-wide text-white">
                One-click access
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
                Click the button below to sign in to your Family Events account. No password needed.
              </Text>
            </Section>

            {/* CTA */}
            <Section className="px-10 pb-4 pt-5 text-center">
              <Button
                href={"{{{MAGIC_LINK}}}"}
                className="inline-block rounded-full bg-peach px-8 py-4 font-sans text-[16px] font-bold text-white"
              >
                Sign in to Family Events
              </Button>
            </Section>

            {/* Expiration notice */}
            <Section className="px-10 pb-9 pt-2 text-center">
              <Text className="m-0 font-mono text-xs tracking-wide text-text-muted">
                This link expires in {"{{{EXPIRES_IN}}}"}
              </Text>
            </Section>

            {/* Footer */}
            <Section className="border-t border-solid border-border bg-bg px-10 py-6">
              <Text className="m-0 text-center font-sans text-xs leading-relaxed text-text-muted">
                If you didn't request this link, you can safely ignore this email.
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
