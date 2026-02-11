# Bot HTTP SDK and Docs Plan

## Goals

1. Add docs for using the Bot HTTP SDK in web docs.
2. Make `@inline-chat/bot-api` match latest bot API behavior and schema.
3. Evaluate and improve rich type exposure for bot API consumers.

## Steps

- [completed] Audit current SDK surface and compare against server bot API.
- [completed] Implement typed bot HTTP client methods and updated request/response contracts.
- [completed] Update SDK tests for the new typed methods and transport options.
- [completed] Update docs (`/docs/sdk` and `/docs/bot-api`) with SDK usage examples.
- [completed] Validate with package-level typecheck/tests and web checks.
- [completed] Document shared-type strategy and what is now exposed.

## Notes

- Keep header auth as default, support token-in-path mode.
- Support POST params in JSON body and query string to match server behavior.
- Canonical target fields: `chat_id` / `user_id` (aliases still typed).
- Rich contracts are now exported directly from `@inline-chat/bot-api` and act as the shared client-side type surface for bot HTTP consumers.
