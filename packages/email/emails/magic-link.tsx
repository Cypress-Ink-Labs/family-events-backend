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

export default function MagicLinkEmail() {
  return (
    <Html>
      <Head />
      <Preview>Your Family Events sign-in link</Preview>
      <Body style={{ backgroundColor: '#f6f9fc', fontFamily: 'sans-serif' }}>
        <Container style={{ backgroundColor: '#ffffff', padding: '40px', borderRadius: '8px', margin: '40px auto', maxWidth: '560px' }}>
          <Heading style={{ fontSize: '24px', color: '#1a1a1a' }}>
            Your sign-in link
          </Heading>
          <Text style={{ fontSize: '16px', color: '#444444' }}>
            Hi {'{{{USERNAME}}}'},
          </Text>
          <Text style={{ fontSize: '16px', color: '#444444' }}>
            Click the button below to sign in to your Family Events account.
          </Text>
          <Button
            href={'{{{MAGIC_LINK}}}'}
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
            Sign In
          </Button>
          <Text style={{ fontSize: '14px', color: '#666666', marginTop: '16px' }}>
            This link expires in {'{{{EXPIRES_IN}}}'}.
          </Text>
          <Hr style={{ borderColor: '#e6e6e6', margin: '32px 0' }} />
          <Text style={{ fontSize: '14px', color: '#999999' }}>
            If you didn't request this, you can safely ignore this email.
          </Text>
        </Container>
      </Body>
    </Html>
  )
}
