# 2GB Video Upload Plan (Telegram-Inspired Multipart)

## Goal
Enable production-ready uploads up to 2GB for videos by replacing single-request in-memory video upload with multipart chunk upload, while preserving existing `/v1/uploadFile` behavior for photos/documents and existing response shapes.

## Constraints
- Keep API style consistent with existing v1 methods and auth model.
- Preserve existing DB file/video model and encryption-at-rest metadata handling.
- Avoid loading full video data into memory on Apple clients.
- Keep non-video upload path unchanged.

## Design Decisions
1. Add dedicated video multipart endpoints (init, part, complete, abort) under v1.
2. Use R2 multipart upload via AWS S3-compatible API server-side.
3. Use signed upload session tokens (HMAC) instead of DB session tables to avoid migration and support stateless scaling.
4. Finalize by creating `files` + `videos` DB rows after multipart completion.
5. Apple client uploads video chunks from file URL using `FileHandle` chunk reads.
6. Keep legacy `/uploadFile` endpoint for photos/documents and compatibility.

## Task Checklist
- [x] Add server multipart storage helper and upload session token utility.
- [x] Add `uploadVideoMultipart` v1 endpoints and wire in controller.
- [x] Refactor file persistence helper to support already-uploaded object paths.
- [x] Add Apple `ApiClient` multipart video methods.
- [x] Parallelize Apple multipart part uploads to improve throughput.
- [x] Switch `InlineKit` video upload flow to multipart (no full `Data(contentsOf:)` for video).
- [x] Switch share extension video upload to multipart API.
- [x] Keep non-video share extension limits unchanged while raising video limit to 2GB.
- [x] Increase video size limit to 2GB-equivalent safe integer bound.
- [x] Run focused checks and fix issues.
- [ ] Commit with scoped message.

## Notes
- Use decimal 2GB (`2_000_000_000`) to avoid `Int32` overflow in `files.fileSize` DB integer column.
- Keep chunk size conservative (8MB) for memory and retry behavior.
- Apple multipart upload now uses 3 parallel workers (Telegram-inspired parallel part upload model) with per-part progress aggregation.
