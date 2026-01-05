# iOS Share Extension Refactor Plan

## Goals
- Fix attachment failures (file uploads producing empty messages).
- Add reliable progress reporting for uploads.
- Harden shared-item parsing (images, files, URLs, text) with clear precedence and logging.
- Add first-class video support (metadata + thumbnail).
- Improve diagnostics for Sentry/Log by capturing provider errors and share session context.

## Non-Goals (for this pass)
- Full UI redesign beyond necessary states.
- Large-scale backend changes.

## Phases
1. **API correctness + progress** ✅
   - Switch share extension to the current `sendMessage` API using `fileUniqueId`.
   - Use InlineKit `ApiClient` upload path with URLSession delegate progress.
   - Ensure text-only shares still work.

2. **Robust parsing + attachment model** ✅
   - Replace ad-hoc provider parsing with a deterministic, priority-based loader.
   - Deduplicate items and avoid double-handling (image+url+text from same provider).
   - Preserve files as temp URLs with security-scoped access.

3. **Video support** ✅
   - Detect movie UTIs, extract metadata (width/height/duration), generate thumbnail.
   - Upload with `MessageFileType.video` and metadata.

4. **Logging + resilience** ✅
   - Add per-share `sessionId` for log correlation.
   - Log all provider load failures with type identifiers.
   - Surface common failure reasons (no auth token, no shared data, max limits).

5. **UX polish (minimal)** ⏳
   - Show aggregate progress and simple attachment summary in the share UI.
   - Keep errors actionable (open main app, retry, file too large).

## Files Likely Touched
- `apple/InlineShareExtension/ShareState.swift`
- `apple/InlineShareExtension/ShareView.swift`
- `apple/InlineIOS/Shared/SharedApiClient.swift` (if retained)
- New helper types in `apple/InlineShareExtension/`

## Open Questions
- Should videos be uploaded as `.video` (with metadata) or sent as document fallback when metadata fails?
- Do we want to support captions in the share UI now, or keep text from shared content only?
