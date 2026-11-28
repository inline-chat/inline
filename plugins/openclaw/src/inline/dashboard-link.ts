import { execFile } from "node:child_process"
import { hostname } from "node:os"
import type { OpenClawConfig } from "openclaw/plugin-sdk/core"

/**
 * The OpenClaw Control UI link Inline opens for an owner who presses "Open
 * Dashboard". It carries a single-use bootstrap token, so the browser is
 * signed in without device pairing.
 */
export type OpenClawDashboardLink = {
  url: string
  hostLabel: string
  /** Set when the link only works on the gateway's own machine. */
  unreachableText?: string
}

export class OpenClawDashboardUnavailableError extends Error {}

type TailscaleRunner = (argv: string[], opts: { timeoutMs: number }) => Promise<{ code: number | null; stdout: string }>

export type OpenClawDashboardDeps = {
  issueBootstrapToken(): Promise<string>
  resolvePublicOrigin(cfg: OpenClawConfig): string | undefined
  resolveTailnetHost(runner: TailscaleRunner): Promise<string | null>
  resolvePort(cfg: OpenClawConfig): number
  hostLabel(): string
  runCommand: TailscaleRunner
}

export const LOOPBACK_ONLY_TEXT =
  "OpenClaw only listens on that computer. To open the dashboard from other devices, turn on Tailscale Serve for the gateway (gateway.tailscale.mode: serve) or set an HTTPS gateway.publicOrigin."

export function normalizeControlUiBasePath(value: string | undefined): string {
  const trimmed = value?.trim() ?? ""
  if (!trimmed || trimmed === "/") return ""
  const withLeading = trimmed.startsWith("/") ? trimmed : `/${trimmed}`
  return withLeading.replace(/\/+$/, "")
}

/** Picks the address other devices can reach, best first: public HTTPS origin, Tailscale, then loopback. */
export async function resolveOpenClawDashboardOrigin(
  cfg: OpenClawConfig,
  deps: Pick<OpenClawDashboardDeps, "resolvePublicOrigin" | "resolveTailnetHost" | "resolvePort" | "runCommand">,
): Promise<{ origin: string; loopbackOnly: boolean }> {
  const publicOrigin = deps.resolvePublicOrigin(cfg)
  const allowedOrigins = cfg.gateway?.controlUi?.allowedOrigins
  if (
    publicOrigin?.startsWith("https://") &&
    (allowedOrigins === undefined ||
      allowedOrigins.some((allowed) => ["*", publicOrigin.toLowerCase()].includes(allowed.trim().toLowerCase())))
  ) {
    return { origin: publicOrigin.replace(/\/+$/, ""), loopbackOnly: false }
  }
  const mode = cfg.gateway?.tailscale?.mode
  if (mode === "serve" || mode === "funnel") {
    const host = await deps.resolveTailnetHost(deps.runCommand).catch(() => null)
    if (host) return { origin: `https://${host}`, loopbackOnly: false }
  }
  const scheme = (cfg.gateway as { tls?: { enabled?: boolean } } | undefined)?.tls?.enabled ? "https" : "http"
  return { origin: `${scheme}://127.0.0.1:${deps.resolvePort(cfg)}`, loopbackOnly: true }
}

export async function buildOpenClawDashboardLink(
  cfg: OpenClawConfig,
  deps: OpenClawDashboardDeps,
): Promise<OpenClawDashboardLink> {
  if (cfg.gateway?.controlUi?.enabled === false) {
    throw new OpenClawDashboardUnavailableError(
      "The OpenClaw Control UI is turned off (gateway.controlUi.enabled).",
    )
  }
  const { origin, loopbackOnly } = await resolveOpenClawDashboardOrigin(cfg, deps)
  const basePath = normalizeControlUiBasePath(cfg.gateway?.controlUi?.basePath)
  // The Control UI serves its WebSocket under the same base path as the page.
  const gatewayUrl = `${origin.replace(/^http/, "ws")}${basePath}`
  const token = await deps.issueBootstrapToken()
  const url = new URL(`${origin}${basePath}/`)
  url.hash = `gatewayUrl=${encodeURIComponent(gatewayUrl)}&bootstrapToken=${encodeURIComponent(token)}`
  return {
    url: url.toString(),
    hostLabel: deps.hostLabel(),
    ...(loopbackOnly ? { unreachableText: LOOPBACK_ONLY_TEXT } : {}),
  }
}

/** The machine's name without the mDNS suffix, as people see it. */
export function localHostLabel(): string {
  return hostname().replace(/\.local$/i, "") || "the OpenClaw computer"
}

function runCommandWithTimeout(argv: string[], opts: { timeoutMs: number }): Promise<{ code: number | null; stdout: string }> {
  const [command, ...args] = argv
  return new Promise((resolve) => {
    if (!command) return resolve({ code: 1, stdout: "" })
    execFile(command, args, { timeout: opts.timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
      const code = error ? (typeof (error as { code?: unknown }).code === "number" ? (error as { code: number }).code : 1) : 0
      resolve({ code, stdout: String(stdout ?? "") })
    })
  })
}

/** The real OpenClaw host functions, loaded on first use. */
export async function defaultOpenClawDashboardDeps(): Promise<OpenClawDashboardDeps> {
  const [bootstrap, contracts, core] = await Promise.all([
    import("openclaw/plugin-sdk/device-bootstrap"),
    import("openclaw/plugin-sdk/config-contracts"),
    import("openclaw/plugin-sdk/core"),
  ])
  return {
    async issueBootstrapToken() {
      // The handoff scopes OpenClaw allows plugins to mint (as its own Telegram
      // "Open Control UI" does); the full owner profile stays host-only.
      const issued = await bootstrap.issueDeviceBootstrapToken({
        profile: {
          roles: ["operator"],
          scopes: bootstrap.BOOTSTRAP_HANDOFF_OPERATOR_SCOPES,
          purpose: "control-ui",
        },
      })
      return issued.token
    },
    resolvePublicOrigin: (cfg) => contracts.resolveGatewayPublicOrigin(cfg) ?? undefined,
    resolveTailnetHost: (runner) => core.resolveTailnetHostWithRunner(runner),
    resolvePort: (cfg) => core.resolveGatewayPort(cfg),
    hostLabel: localHostLabel,
    runCommand: runCommandWithTimeout,
  }
}
