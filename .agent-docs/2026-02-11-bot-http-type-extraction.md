# Bot HTTP Type Extraction

## Goal

Create a proper shared contract package for Bot HTTP API types and use it across server and SDK to avoid drift.

## Plan

- [completed] Create `@inline-chat/bot-api-types` package with canonical contracts.
- [completed] Refactor `@inline-chat/bot-api` to import/re-export shared contracts.
- [completed] Type server bot response mappers against shared contracts.
- [completed] Update workspace dependency/tsconfig references.
- [completed] Run typecheck/tests across touched packages and server/web.

## Status Notes

- Keep runtime Elysia schemas in server for validation/docs.
- Move only static contracts and method params/results into shared package.
- Added typed method maps (`BotMethodName`, params/result lookup types) for SDK method inference.
- Validation run:
  - `cd packages/bot-api-types && bun run typecheck && bun run build`
  - `cd packages/bot-api && bun run typecheck && bun test && bun run build`
  - `cd server && bun run typecheck`
  - `cd server && bun test src/__tests__/bot-api.test.ts`
  - `cd web && bun run typecheck`
