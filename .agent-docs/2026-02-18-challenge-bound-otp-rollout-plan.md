# Challenge-Bound OTP Rollout Plan

Date: 2026-02-18
Owner: Server + Web + Apple
Status: In Progress

## Goal

Implement challenge-bound email OTP login while keeping backward compatibility for older clients that do not send a challenge token.

## Tasks

1. Server schema + migration
- [x] Convert `login_codes` to challenge-oriented storage.
- [x] Add nullable `challenge_id` and indexes for challenge/email lookup.
- [x] Keep integrity check for `code OR code_hash` presence.

2. Server API behavior
- [x] `sendEmailCode` returns optional `challengeToken`.
- [x] `verifyEmailCode` accepts optional `challengeToken`.
- [x] Token path verifies scoped challenge only.
- [x] Backward-compatible path verifies without token for legacy clients.

3. Web login flow
- [x] Capture `challengeToken` from send response.
- [x] Persist token across login code route + resend.
- [x] Pass token on verify when present.

4. iOS/macOS login flows
- [x] Add token field in shared API models (`InlineKit`).
- [x] Pass token from send->verify in iOS onboarding flow.
- [x] Pass token from send->verify in macOS onboarding flow.

5. Validation
- [x] Update/add tests for token + fallback paths.
- [x] Run focused server tests + typecheck.
- [x] Run `web` typecheck.
- [x] Run `swift build` for `apple/InlineKit`.

## Notes

- Backward compatibility requirement: old clients must continue logging in using only `email + code`.
- Security priority: no plaintext OTP persistence for new writes.
- iOS/macOS app target builds (`xcodebuild`) were not run per repo rule; only `InlineKit` package build was run.
