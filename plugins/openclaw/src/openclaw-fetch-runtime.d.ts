// OpenClaw ships `openclaw/plugin-sdk/fetch-runtime` without declarations.
// Only the read-authority export is typed; older hosts (2026.9.x) lack it.
declare module "openclaw/plugin-sdk/fetch-runtime" {
  export const captureChannelReadAuthority: (() => (() => void) | undefined) | undefined
}
