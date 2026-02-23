# ChatGPT App Submission Checklist (Inline MCP)

Last validated: 2026-02-23

## 1) Required Endpoint Readiness

Status: PASS

- Production MCP server is publicly reachable at `https://mcp.inline.chat`.
- OAuth resource metadata endpoint works:
  - `https://mcp.inline.chat/.well-known/oauth-protected-resource`
- OAuth authorization server metadata endpoint works:
  - `https://mcp.inline.chat/.well-known/oauth-authorization-server`
- MCP endpoint works and returns OAuth challenge when unauthenticated:
  - `POST https://mcp.inline.chat/mcp` returns `401` with `WWW-Authenticate`.

## 2) Tool Safety + Quality Metadata

Status: PASS

- Read-only tools are marked with `readOnlyHint: true`.
- Mutating tools (`conversations.create`, `messages.send*`, `files.upload`) are marked with `readOnlyHint: false`.
- `files.upload` is marked `openWorldHint: true` (it can fetch external HTTPS URLs).
- All other tools remain `openWorldHint: false`.
- Mutating tools require `messages:write` scope checks server-side.

## 3) Security Controls

Status: PASS

- URL upload hardening in `files.upload`:
  - HTTPS-only sources
  - URL credential rejection
  - DNS/IP private/local/link-local/reserved blocking
  - redirect limit
  - fetch timeout
  - max payload size
  - filename sanitization
- OAuth-protected resource flow implemented.
- Host/origin allowlist checks implemented at app boundary.

## 4) Manual Submission Portal Items

Status: ACTION REQUIRED (manual, outside code)

Before clicking submit, verify these in the OpenAI app submission form:

- Privacy policy URL is set and publicly accessible.
- Terms of use URL is set and publicly accessible.
- Support contact email is valid and monitored.
- App description and user benefit are clear and accurate.
- OAuth consent text accurately reflects scopes/behavior.

## 5) CSP Requirement Note

Current status: N/A for components.

- This MCP server currently exposes tools only and does not register iframe/UI resources.
- If UI resources are added later, define explicit widget CSP allowlists (exact domains only) before submission updates.

## 6) Recommended Final Dry Run

Use a clean ChatGPT test account and verify:

1. Connect + OAuth sign-in.
2. `conversations.create` with participants and optional `spaceId`.
3. `files.upload` (base64 and HTTPS URL source).
4. `messages.send_media`.
5. `messages.send_batch` with mixed text/media in order.

