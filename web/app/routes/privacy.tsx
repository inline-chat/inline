import type { Route } from "./+types/home"
import * as stylex from "@stylexjs/stylex"

import { PageMenu } from "../landing/components/PageMenu"
import { PageContainer, PageLongFormContent, PageHeader } from "../landing/components/Page"
import { PageFooter } from "../landing/components/PageFooter"
import { PageMarkdown } from "~/landing/components/PageMarkdown"

import "../landing/styles/style.css"
import "../landing/styles/page-content.css"

export const meta = ({}: Route.MetaArgs) => {
  return [
    { title: "Privacy Policy - Inline" },
    {
      name: "description",
      content: "We're commited to protect Inline users' privacy and data while providing a great user experience.",
    },
  ]
}

export const links: Route.LinksFunction = () => {
  return []
}

export default function Privacy() {
  return (
    <>
      <PageMenu />

      <PageContainer>
        <PageHeader title="Privacy Policy" />
        <PageLongFormContent>
          <PageMarkdown className="page-content">{PRIVACY_POLICY}</PageMarkdown>
        </PageLongFormContent>
      </PageContainer>

      <PageFooter />
    </>
  )
}

const styles = stylex.create({})

const PRIVACY_POLICY = `
## Key Points

- We never sell your data or use it for advertising
- You have full control over your data - export, delete, or modify at any time
- Your messages, files, and sensitive data are encrypted both in storage and transit - we use strong encryption to protect your data at all times
- Your data is private - only you and those you choose to communicate with can access it and we do not process your data for any other purpose than exchanging data with whom you intended and what you've requested us to do 
- We're transparent about everything we do - our client apps are open source and we document everything we do in this policy


## 1. Introduction

This Privacy Policy explains how Inline ("we", "us", "our") collects, uses, and protects your personal information when you use our chat application and related services (the "Services"). We are committed to protecting your privacy and handling your data transparently.

### 1.1 Our Promises to You
- Your data is encrypted
- We never sell your data nor show you ads
- You control your data
- We're transparent about everything we do
- Our client apps are open source

## 2. Information We Collect

### How We Protect Your Data

All data in Inline is encrypted:
- Messages and files are encrypted in storage and transit
- Your personal information is encrypted in our databases
- Local data on your devices is encrypted
- All network communication uses strong encryption

Note that we can't offer full end-to-end encryption because there's really no right way to support bots, specific AI features, cloud sync for spaces, with end-to-end encryption. We've been exploring different options but haven't found viable solution yet. However we protect your data with strong encryption at every step from our servers to the locally data stored on your devices. We are committed to protecting your data the best we can so you're secure and we sleep better at nights.

### 2.1 Account Information
- Name
- Email address or phone number (depending on login method)
- Profile information (optional profile photo and username)

### 2.2 Communication Data
- Messages and communications content
- Shared files, photos, and videos (up to 50MB per file)
- Public community and chat content
- Message edits (without edit history)

### 2.3 Technical Information
- Device information
- IP addresses
- Session information (retained for 90 days)
- Authentication tokens (stored in hashed format)
- Error and crash reports via Sentry (retained for 90 days)
- Optional telemetry data via PostHog for measuring daily active users
- System logs (retained for 90 days)

### 2.4 Service Information
- Open-source client applications (macOS, iOS, and web)
- Public API specification
- Service status (available at status.inline.chat)
- Encrypted backups of user data

## 3. How We Use Your Information

### 3.1 Providing Our Services
- Delivering messages and content
- Managing your account and authentication
- Enabling search functionality
- Supporting file sharing and storage
- Maintaining public communities and chats
- Providing unlimited message history
- Enabling cloud sync across multiple devices
- Processing and storing encrypted backups

### 3.2 Making Inline Better and Safer
We also use data to:
- Keep your account secure
- Spot and stop suspicious activity
- Fix bugs and improve performance
- Make sure everything's working properly
- Learn how we can make Inline better

### 3.3 Staying in Touch
We'll contact you only for:
- Important updates about Inline
- Responses to your support requests
- Security alerts
- Product updates (you can opt out)

### 3.4 Legal Compliance
- Complying with legal obligations
- Responding to legal requests
- Enforcing our terms of service
- Protecting our rights and users

## 4. Data Storage and Security

### 4.1 How We Store Your Data
- Everything you store in Inline is encrypted
- Messages, files, and personal data are encrypted using AES-256-GCM
- All data travels between your devices and our servers using encrypted connections
- We store your data on secure servers in Europe
- Our open-source apps encrypt local data on your device

### 4.2 Security Measures
We take your privacy seriously:
- Only founders have access to the systems storing your data
- We use strong encryption for all sensitive data
- Your sessions are protected with secure tokens
- We monitor for suspicious activity
- We automatically delete old logs after 90 days
- Our client apps are open source so anyone can verify our security
- We regularly test and improve our security measures

### 4.3 Data Breach Procedures
- Immediate investigation of potential breaches
- Prompt notification to affected users via email
- Detailed incident reports and remediation steps
- Cooperation with relevant authorities when required

### 4.4 Transparency
- Open-source client applications enable community security review
- Public API documentation
- Real-time service status monitoring
- Regular security and transparency reports

## 5. Your Rights and Controls

### 5.1 You're in Control
You can:
- See all your active sessions
- Log out from any device
- Choose who can see your profile
- Control who can find you
- Manage your notifications
- Export your data anytime
- Delete your account

### 5.2 Data Rights
You have the right to:
- Access your personal data
- Export your chat history (in SQLite format)
- Correct inaccurate personal information
- Delete specific messages or content
- Delete your account and all associated data
- Opt-out of non-essential communications
- Access open-source clients for transparency

### 5.3 Account Deletion
- Account deletion is immediate upon request
- Send deletion request from your account email to support@inline.chat
- All associated messages and files are permanently deleted
- Deletion is irreversible
- System logs are automatically purged after 90 days

### 5.4 Data Portability
- Export your complete chat history
- Download your shared files and media
- Receive your data in a machine-readable format
- Transfer your data to another service (where technically feasible)
- Access your data through our public API specification

### 5.5 California Privacy Rights (CCPA)
California residents have the right to:
- Know what personal information is collected
- Know whether personal information is sold or disclosed
- Say no to the sale of personal information
- Access their personal information
- Request deletion of their personal information
- Equal service and price, even if they exercise their privacy rights

### 5.6 European Privacy Rights (GDPR)
EU residents have the right to:
- Access their personal data
- Rectify inaccurate personal data
- Erase their personal data
- Restrict or object to data processing
- Data portability
- Lodge a complaint with supervisory authorities

## 6. Data Sharing and Third Parties

### 6.1 Third-Party Services
We only share the minimum required data with trusted services that help us provide specific features. When we do, your data is always encrypted in transit:
- Sentry for error tracking and crash reporting
- PostHog for optional telemetry and usage analytics
- Cloudflare R2 for encrypted file storage
- Amazon SES and Resend for sending emails
- Twilio for sending login SMS codes
- Apple Push Notification service (APNs) for delivering notifications
- OpenAI and Anthropic services (optional, only when explicitly requested by users)
- None of these services are used for advertising or user profiling

### 6.2 Data Processing Agreements
- We maintain appropriate data processing agreements with our service providers
- All service providers are contractually obligated to protect your data
- Service providers may only use data for specified purposes
- Third-party AI services (OpenAI and Anthropic) are only used when explicitly requested by users
- All data sharing is conducted with appropriate security measures

### 6.3 No Sale of Data
- We do not sell your personal information
- We do not share your data with third parties for marketing purposes
- We do not use your data for advertising purposes
- We maintain transparency about all data processing activities

### 6.4 Legal Requirements
We may share information if required to:
- Comply with legal obligations
- Respond to valid legal requests
- Protect our rights or property
- Prevent fraud or abuse
- Ensure user safety

## 7. Children's Privacy

### 7.1 Age Restrictions
- Our Services are not intended for users under 13 years of age
- We do not knowingly collect information from children under 13
- If we learn we have collected information from a child under 13, we will delete it
- Parents or guardians who believe we have inadvertently collected such information should contact us

## 8. Updates

### 8.1 Keeping You Updated
- We'll email you about important privacy changes
- New features will come with clear privacy explanations
- You'll always find the latest policy on our website
- We'll ask for your permission when needed
- Everything will be documented publicly

## 9. Contact Information

### 9.1 Support and Privacy Inquiries
For any questions about this Privacy Policy or our privacy practices:
- Primary Contact: support@inline.chat
- In-App Support: Message @mo in the Inline app
- Social Media: @morajabi on X (Twitter)
- Response Time: We aim to respond to all privacy-related inquiries within 48 hours
- Service Status: status.inline.chat

### 9.2 Policy Updates
- Last Updated: January 8, 2025
- Effective: January 8, 2025


We reserve the right to update this Privacy Policy as needed. Significant changes will be communicated directly to users, and continued use of our Services after such changes constitutes acceptance of the updated Privacy Policy.


`
