# Instructions for server

## Scope

- The backend uses Bun, TypeScript, and Effect. `server/src/index.ts` is the entry point; `src/core/http/productionHost.ts` owns the production HTTP/WebSocket host, `src/functions/` contains retained business operations, and `src/db/` owns schema and models.
- Realtime V2 and V3 coexist. Trace the current contract and routing through `src/realtime/` and `src/core/http/realtimeV3Host.ts` before adding a client-facing API.

## Effect references

- For unfamiliar Effect APIs, inspect the installed `server/node_modules/effect` package and this server's `src/core/effect/` code first. Match examples to the Effect version used here.
- For broader patterns, use the ignored `.references/effect/` checkout at the repo root; clone Effect there if absent. Check examples against the installed version and adapt them to Inline's error, dependency, and lifecycle conventions.

## Data and lifecycle

- Schema lives in `src/db/schema/` and forward Drizzle migrations in `drizzle/`. Generate with `bun run db:generate <name>` from `server/`; review the SQL and never edit a committed migration. Startup checks the migration ledger; `db:migrate` is a separate database mutation.
- PostgreSQL is authoritative; Redis Pub/Sub provides wake-up hints, so retain durable catch-up and repair paths when changing delivery.
- Follow existing encryption patterns in `src/modules/encryption/` and privacy-safe `Log`/Sentry handling. Add shutdown cleanup for new long-lived resources, and account for downtime, retries, and sync correctness in write paths.
- Access production only when authorized; keep inspection read-only by default and require explicit authorization for mutations.

## Checks

- Use [TESTING.md](TESTING.md) for focused and database-backed tests. From `server/`, run the relevant `bun test <path>`, then `bun run typecheck` and `bun run lint` at a checkpoint. Start `bun run dev` only when local runtime validation is needed.
- Write useful tests. Try to avoid mocking modules or testing mere implementation detail with no actual gain other than a copy of the implementation steps.
- Avoid `any` types or suppressing errors. Be strict with type-safety, using effect schema, and idiomatic patterns when it's possible and useful. Escape only in experiments or one-off hot fixes we will refactor later.