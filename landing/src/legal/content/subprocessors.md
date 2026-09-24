# Subprocessors

Last updated: September 23, 2026.

Inline uses the following third-party providers to operate the Services. Which providers process customer data may vary by deployment and by the features a customer uses.

## Infrastructure and Storage

| Provider | Purpose |
| --- | --- |
| Fly.io | Cloud hosting and infrastructure services. |
| Hetzner Cloud | Cloud hosting and infrastructure services. |
| PlanetScale | Managed database services. |
| Cloudflare R2 | File and media object storage. |

## Authentication and Communications

| Provider | Purpose |
| --- | --- |
| Amazon Web Services SES | Transactional email delivery. |
| Resend | Transactional email delivery. |
| Prelude | Phone verification and SMS login codes. |
| Twilio | Legacy phone verification, SMS login support, and phone number lookup. |
| Apple | Sign in with Apple and delivery of iOS and macOS push notifications. |
| Google | Optional Sign in with Google authentication. |

## Monitoring and Analytics

| Provider | Purpose |
| --- | --- |
| Sentry | Error tracking, crash reporting, performance diagnostics, and release diagnostics. |
| IPinfo | Approximate IP-based location lookup for waitlist and abuse-prevention workflows. |

## AI Providers

| Provider | Purpose |
| --- | --- |
| OpenAI | Optional AI-assisted features, task drafting, notification evaluation, and related product workflows. |

## User-Enabled Integrations and Recipient Services

These providers receive data only when a user or space connects the integration, triggers a workflow, or sends content to the service.

| Provider | Purpose |
| --- | --- |
| Notion | Creating and managing user-requested Notion tasks and reading selected Notion metadata. |
| Linear | Creating and managing user-requested Linear issues and reading selected Linear metadata. |
| Loom | Link preview metadata for Loom URLs shared in Inline. |

Questions about subprocessors can be sent to [hey@inline.chat](mailto:hey@inline.chat).
