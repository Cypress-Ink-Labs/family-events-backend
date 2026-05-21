import {
  Body,
  Button,
  Container,
  Head,
  Heading,
  Hr,
  Html,
  Preview,
  Text,
} from 'react-email'

export default function WelcomeEmail() {
  return (
    <Html>
      <Head />
      <Preview>Welcome to Family Events</Preview>
      <Body style={{ backgroundColor: '#f6f9fc', fontFamily: 'sans-serif' }}>
        <Container style={{ backgroundColor: '#ffffff', padding: '40px', borderRadius: '8px', margin: '40px auto', maxWidth: '560px' }}>
          <Heading style={{ fontSize: '24px', color: '#1a1a1a' }}>
            Welcome to Family Events!
          </Heading>
          <Text style={{ fontSize: '16px', color: '#444444' }}>
            Hi {'{{{USERNAME}}}'},
          </Text>
          <Text style={{ fontSize: '16px', color: '#444444' }}>
            We're thrilled to have you on board. Family Events helps you stay connected with the people who matter most.
          </Text>
          <Button
            href={'{{{APP_URL}}}'}
            style={{
              backgroundColor: '#4f46e5',
              color: '#ffffff',
              padding: '12px 24px',
              borderRadius: '6px',
              fontSize: '16px',
              textDecoration: 'none',
              display: 'inline-block',
            }}
          >
            Get Started
          </Button>
          <Hr style={{ borderColor: '#e6e6e6', margin: '32px 0' }} />
          <Text style={{ fontSize: '12px', color: '#999999' }}>
            You're receiving this email because you signed up for Family Events.
          </Text>
        </Container>
      </Body>
    </Html>
  )
}
