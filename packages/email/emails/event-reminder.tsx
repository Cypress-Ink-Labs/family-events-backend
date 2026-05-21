import {
  Body,
  Button,
  Container,
  Head,
  Heading,
  Hr,
  Html,
  Preview,
  Section,
  Text,
} from "react-email"

export default function EventReminderEmail() {
  return (
    <Html>
      <Head />
      <Preview>Reminder: {"{{{EVENT_TITLE}}}"} is coming up</Preview>
      <Body style={{ backgroundColor: "#f6f9fc", fontFamily: "sans-serif" }}>
        <Container
          style={{
            backgroundColor: "#ffffff",
            padding: "40px",
            borderRadius: "8px",
            margin: "40px auto",
            maxWidth: "560px",
          }}
        >
          <Heading style={{ fontSize: "24px", color: "#1a1a1a" }}>Event Reminder</Heading>
          <Text style={{ fontSize: "16px", color: "#444444" }}>Hi {"{{{USERNAME}}}"},</Text>
          <Text style={{ fontSize: "16px", color: "#444444" }}>
            Just a reminder that {"{{{EVENT_TITLE}}}"} is coming up soon.
          </Text>
          <Section
            style={{
              backgroundColor: "#f9fafb",
              padding: "16px",
              borderRadius: "6px",
              margin: "24px 0",
            }}
          >
            <Text
              style={{
                fontSize: "16px",
                color: "#1a1a1a",
                margin: "0 0 8px 0",
                fontWeight: "bold",
              }}
            >
              {"{{{EVENT_TITLE}}}"}
            </Text>
            <Text style={{ fontSize: "14px", color: "#666666", margin: "0 0 4px 0" }}>
              {"{{{EVENT_DATE}}}"}
            </Text>
            <Text style={{ fontSize: "14px", color: "#666666", margin: "0" }}>
              {"{{{EVENT_LOCATION}}}"}
            </Text>
          </Section>
          <Button
            href={"{{{EVENT_URL}}}"}
            style={{
              backgroundColor: "#4f46e5",
              color: "#ffffff",
              padding: "12px 24px",
              borderRadius: "6px",
              fontSize: "16px",
              textDecoration: "none",
              display: "inline-block",
            }}
          >
            View Event
          </Button>
          <Hr style={{ borderColor: "#e6e6e6", margin: "32px 0" }} />
          <Text style={{ fontSize: "12px", color: "#999999" }}>
            You're receiving this reminder because you're attending {"{{{EVENT_TITLE}}}"}.
          </Text>
        </Container>
      </Body>
    </Html>
  )
}
