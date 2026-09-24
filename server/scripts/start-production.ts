const artifactSmokeRequested =
  process.argv.includes(
    "--artifact-smoke",
  )
if (
  artifactSmokeRequested &&
  process.env["INLINE_SERVER_SMOKE"] !== "1"
) {
  throw new Error(
    "--artifact-smoke requires INLINE_SERVER_SMOKE=1.",
  )
}

const { runServer } =
  await import(
    new URL(
      "../dist/index.js",
      import.meta.url,
    ).href
  )

// The packaged artifact must be startable in CI without production signing
// secrets. This explicit harness-only injection preserves the normal
// production entrypoint's fail-closed Inline Protocol configuration.
await runServer(
  artifactSmokeRequested
    ? {
      inlineProtocolConfiguration: {
        enabled: false,
      },
      // The smoke harness supplies an isolated database but no Redis broker.
      // Keep this bypass local to the guarded artifact-only entrypoint; normal
      // production startup must establish the cluster before it serves traffic.
      startClusterServices: false,
    }
    : undefined,
)
