// Release versions belong to immutable tags; source manifests stay independent.
export const PACKAGE_CONFIGS = {
  protocol: { key: "protocol", directory: "packages/protocol", name: "@inline-chat/protocol" },
  "bot-api-types": { key: "bot-api-types", directory: "packages/bot-api-types", name: "@inline-chat/bot-api-types" },
  "bot-client": { key: "bot-client", directory: "packages/bot-client", name: "@inline-chat/bot-client" },
  "realtime-sdk": { key: "realtime-sdk", directory: "packages/sdk", name: "@inline-chat/realtime-sdk" },
  openclaw: { key: "openclaw", directory: "plugins/openclaw", name: "@inline-openclaw/inline" },
  "hermes-agent": { key: "hermes-agent", directory: "plugins/hermes-agent", name: "@inline-chat/hermes-agent-adapter" },
  "chat-sdk": { key: "chat-sdk", directory: "plugins/chat-sdk-plugin", name: "@inline-chat/chat-sdk" },
}

export function canonicalSemver(value) {
  if (typeof value !== "string" || value !== value.trim() || value.length > 150 ||
      !/^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(value)) {
    throw new Error(`Invalid canonical release version: ${String(value)}`)
  }
  // npm strips build metadata from version identity, so it is not accepted in tags.
  const prerelease = value.split("-").slice(1).join("-")
  if (prerelease.split(".").some((part) => /^\d+$/.test(part) && part.length > 1 && part.startsWith("0"))) {
    throw new Error(`Invalid canonical release version: ${value}`)
  }
  return value
}

export function parseReleaseTag(tag, expectedSurface) {
  if (typeof tag !== "string") throw new Error("A release tag is required")
  const key = ["cli", ...Object.keys(PACKAGE_CONFIGS)].find((name) => tag.startsWith(`${name}-v`))
  if (!key) throw new Error(`Unsupported release tag: ${tag}`)
  const version = canonicalSemver(tag.slice(key.length + 2))
  const surface = key === "cli" ? "cli" : "npm"
  if (expectedSurface && surface !== expectedSurface) throw new Error(`Expected a ${expectedSurface} release tag`)
  const channel = version.includes("-") ? version.slice(version.indexOf("-") + 1).split(".")[0] : "latest"
  if (surface === "npm" && !["latest", "alpha", "beta", "next"].includes(channel)) {
    throw new Error(`Unsupported npm prerelease channel: ${channel}`)
  }
  return { tag, surface, packageKey: key, version, channel, ...PACKAGE_CONFIGS[key] }
}
