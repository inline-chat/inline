# Pinned MCP wire schema

Unmodified official MCP 2026-07-28 JSON Schema from commit `271ecc9accafdd9b83a3c869fa67c22953b2af80`.

Source: https://github.com/modelcontextprotocol/modelcontextprotocol/blob/271ecc9accafdd9b83a3c869fa67c22953b2af80/schema/2026-07-28/schema.json

SHA-256: `ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203`. The unmodified upstream license and its MIT-to-Apache transition notice are included.

The compiled HTTP check loads this locally, without a network fetch. Preserve the full schema so new required fields and nested descriptor constraints cannot disappear in a hand-maintained subset. Validate both the response envelope and its complete-result branch: the resources/read envelope also accepts an extensible input-required branch.

When updating protocol support or refreshing this fixture, download the exact version from a reviewed upstream commit, update this provenance and the receipt commit in check-chatgpt-plugin.mjs, then run `bun run check:chatgpt-plugin`. Do not change expected fields just to make a failed schema check pass. Events use their separate draft and are qualified by the backend Events suite.
