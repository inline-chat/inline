import { expect, test } from "bun:test"
import { mkdtemp, mkdir, readFile, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { resolve } from "node:path"
import { isBuildInput, prepareServerContext } from "./server-context"

test("context excludes configuration, credentials and generated files before reading blobs", () => {
  for (const path of [
    "server/.env",
    "server/.env.production",
    "server/src/.env.local",
    "server/key.pem",
    "server/id.key",
    "server/dist/index.js",
    "server/node_modules/a/index.js",
    "server/cache.db",
    "server/.private/key",
    "server/.git/config",
  ]) {
    expect(isBuildInput(path), path).toBe(false)
  }
  expect(isBuildInput("server/src/index.ts")).toBe(true)
  expect(isBuildInput("server/Dockerfile.dockerignore")).toBe(true)
})

test("context exports committed dependency closure, ignores dirty/untracked input, and refuses reuse or symlinks", async () => {
  const temp = await mkdtemp(resolve(tmpdir(), "inline-server-context-"))
  const root = resolve(temp, "repo")
  await mkdir(root)
  const files: Record<string, string> = {
    "package.json": JSON.stringify({ workspaces: ["server", "packages/*"] }),
    "bun.lock": "fixture lock",
    "bunfig.toml": "",
    "server/package.json": JSON.stringify({
      name: "@inline-chat/server",
      dependencies: { "fixture-dependency": "workspace:*" },
    }),
    "server/src/index.ts": "export const source = 'committed'",
    "server/Dockerfile": "FROM scratch",
    "server/Dockerfile.dockerignore": "**/.env*",
    "packages/dependency/package.json": JSON.stringify({
      name: "fixture-dependency",
    }),
    "packages/dependency/index.ts": "export const dependency = true",
    "packages/unused/package.json": JSON.stringify({ name: "unused" }),
    "packages/unused/index.ts": "not a build input",
    "scripts/docker/prune-workspace.ts": "",
    "scripts/docker/smoke-artifact.ts": "",
  }
  for (const [path, content] of Object.entries(files)) {
    await mkdir(resolve(root, path, ".."), { recursive: true })
    await writeFile(resolve(root, path), content)
  }
  const git = async (...args: string[]) => {
    const child = Bun.spawn(["git", "-C", root, ...args], {
      env: {
        PATH: process.env.PATH,
        GIT_CONFIG_NOSYSTEM: "1",
        GIT_CONFIG_GLOBAL: "/dev/null",
      },
      stdout: "pipe",
      stderr: "pipe",
    })
    const error = await new Response(child.stderr).text()
    expect(await child.exited, error).toBe(0)
  }
  await git("init")
  await git("add", ".")
  await git(
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "Fixture",
  )
  await writeFile(resolve(root, "server/src/index.ts"), "dirty source")
  await writeFile(resolve(root, "server/untracked.txt"), "not in commit")
  const output = resolve(temp, "context")
  const result = await prepareServerContext(root, "HEAD", output)
  expect(await readFile(resolve(output, "server/src/index.ts"), "utf8")).toBe(files["server/src/index.ts"]!)
  expect(result.files).toContain("packages/dependency/index.ts")
  expect(result.files).toContain("packages/unused/package.json")
  expect(result.files).not.toContain("packages/unused/index.ts")
  expect(result.files).not.toContain("server/untracked.txt")
  expect(JSON.parse(await readFile(resolve(output, "source.json"), "utf8")).commit).toMatch(/^[a-f0-9]{40}$/)
  await expect(prepareServerContext(root, "HEAD", output)).rejects.toThrow()
  await symlink("../../packages/unused/index.ts", resolve(root, "server/src/link.ts"))
  await git("add", "server/src/link.ts")
  await git(
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-m",
    "Symlink",
  )
  await expect(prepareServerContext(root, "HEAD", resolve(temp, "rejected"))).rejects.toThrow("regular files")
})

test("Fly configuration keeps a dark Machine private and reserves workers for the active API", async () => {
  const root = resolve(import.meta.dir, "../..")
  const config = Bun.TOML.parse(await readFile(resolve(root, "server/fly.toml"), "utf8")) as {
    app?: string
    build: Record<string, string>
    deploy: Record<string, string>
    kill_signal: string
    kill_timeout: string
    env: Record<string, string>
    http_service: { auto_stop_machines: string; checks: { path: string; headers: Record<string, string> }[] }
  }
  expect(config.app).toBe("inline-api")
  expect(config.build).toEqual({
    image: "REPLACE_WITH_IMMUTABLE_IMAGE_DIGEST",
  })
  expect(config.deploy).toEqual({ strategy: "bluegreen" })
  expect(config.kill_signal).toBe("SIGTERM")
  expect(parseInt(config.kill_timeout) * 1000).toBeGreaterThan(20_000)
  expect(config.env.INLINE_PROCESS_ROLE).toBe("all")
  expect(config.env.INLINE_INGRESS_MODE).toBe("cloudflare")
  expect(config.env.INLINE_INGRESS_HOST).toBe("api.inline.chat")
  expect(config.env.INLINE_TRUSTED_CLIENT_IP_HEADER).toBe("cf-connecting-ip")
  expect(config.env.SHUTDOWN_TIMEOUT_MS).toBe("40000")
  expect(config.http_service.auto_stop_machines).toBe("off")
  expect(config.http_service.checks[0].path).toBe("/readyz")
  expect(config.http_service.checks[0].headers).toEqual({ "X-Forwarded-Proto": "https" })

  const dark = JSON.parse(await readFile(resolve(root, "server/fly.dark-machine.json"), "utf8")) as {
    image: string
    env: Record<string, string>
    guest: { cpu_kind: string; cpus: number; memory_mb: number }
    metadata: Record<string, string>
    restart: { policy: string; max_retries: number }
    services?: unknown
  }
  expect(dark.image).toBe("REPLACE_WITH_IMMUTABLE_IMAGE_DIGEST")
  expect(dark.env).toEqual({
    NODE_ENV: "production",
    PORT: "8000",
    INLINE_PROCESS_ROLE: "api",
    INLINE_INGRESS_MODE: "cloudflare",
    INLINE_INGRESS_HOST: "api.inline.chat",
    INLINE_TRUSTED_CLIENT_IP_HEADER: "cf-connecting-ip",
    SHUTDOWN_TIMEOUT_MS: "40000",
  })
  expect(dark.services).toBeUndefined()
  expect(dark.guest).toEqual({ cpu_kind: "shared", cpus: 6, memory_mb: 1536 })
  expect(dark.metadata).toEqual({ fly_platform_version: "v2", fly_process_group: "app" })
  expect(dark.restart).toEqual({ policy: "on-failure", max_retries: 10 })

  const deploymentGuide = await readFile(resolve(root, "server/docs/fly-deployment.md"), "utf8")
  expect(deploymentGuide).toContain("must not be promoted implicitly")
  expect(deploymentGuide).toContain("cannot be moved into `inline-api`")
})
