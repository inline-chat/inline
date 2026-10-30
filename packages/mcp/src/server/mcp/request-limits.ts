// Keep the existing 25 MiB upload tool usable after base64 encoding and JSON.
export const MAX_MCP_REQUEST_BYTES = 40 * 1024 * 1024

// Bound validation work independently of byte size: many tiny values can create
// far more validation issues than a large string or upload would.
export const MAX_MCP_TOOL_INPUT_ELEMENTS = 10_000
