import { spawn, spawnSync, type ChildProcessWithoutNullStreams } from "node:child_process"
import http from "node:http"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import { afterEach, describe, expect, it } from "vitest"

const dirs: string[] = []
const packageRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe("sidecar runtime", () => {
  it("rejects non-loopback bind addresses", async () => {
    const dir = await tempDir()
    const outdir = path.join(dir, "bundle")
    buildSidecarBundle(outdir)

    const port = await getOpenPort()
    const sidecar = spawn(process.execPath, [path.join(outdir, "index.mjs")], {
      cwd: dir,
      env: {
        ...process.env,
        INLINE_TOKEN: "fake-inline-token",
        INLINE_SIDECAR_TOKEN: "runtime-token",
        INLINE_SIDECAR_PORT: String(port),
        INLINE_SIDECAR_BIND: "0.0.0.0",
        INLINE_STATE_PATH: path.join(dir, "state.json"),
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    const logs = collectOutput(sidecar)

    await waitForExit(sidecar, 2_000)

    expect(sidecar.exitCode).toBe(2)
    expect(logs()).toContain("INLINE_SIDECAR_BIND must be loopback")
  })

  it("rejects invalid sidecar ports", async () => {
    const dir = await tempDir()
    const outdir = path.join(dir, "bundle")
    buildSidecarBundle(outdir)

    const sidecar = spawn(process.execPath, [path.join(outdir, "index.mjs")], {
      cwd: dir,
      env: {
        ...process.env,
        INLINE_TOKEN: "fake-inline-token",
        INLINE_SIDECAR_TOKEN: "runtime-token",
        INLINE_SIDECAR_PORT: "70000",
        INLINE_SIDECAR_BIND: "127.0.0.1",
        INLINE_STATE_PATH: path.join(dir, "state.json"),
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    const logs = collectOutput(sidecar)

    await waitForExit(sidecar, 2_000)

    expect(sidecar.exitCode).toBe(2)
    expect(logs()).toContain("INLINE_SIDECAR_PORT must be an integer from 1 to 65535")
  })

  it("requires the sidecar token for health checks", async () => {
    const dir = await tempDir()
    const outdir = path.join(dir, "bundle")
    buildSidecarBundle(outdir)

    const port = await getOpenPort()
    const token = "runtime-token"
    const sidecar = spawn(process.execPath, [path.join(outdir, "index.mjs")], {
      cwd: dir,
      env: {
        ...process.env,
        INLINE_TOKEN: "fake-inline-token",
        INLINE_SIDECAR_TOKEN: token,
        INLINE_SIDECAR_PORT: String(port),
        INLINE_SIDECAR_BIND: "127.0.0.1",
        INLINE_STATE_PATH: path.join(dir, "state.json"),
        INLINE_CONNECT_RETRY_INITIAL_MS: "100",
        INLINE_CONNECT_RETRY_MAX_MS: "100",
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    const logs = collectOutput(sidecar)

    try {
      await waitForHttp(port, sidecar, logs)

      const unauthorized = await post(port, "/healthz", {}, {})
      expect(unauthorized.status).toBe(401)
      expect(unauthorized.body).toMatchObject({ ok: false, errorKind: "forbidden" })

      const wrongToken = await post(port, "/healthz", {}, { "x-hermes-sidecar-token": "wrong-token" })
      expect(wrongToken.status).toBe(401)
      expect(wrongToken.body).toMatchObject({ ok: false, errorKind: "forbidden" })

      const duplicateToken = await post(port, "/healthz", {}, { "x-hermes-sidecar-token": [token, token] })
      expect(duplicateToken.status).toBe(401)
      expect(duplicateToken.body).toMatchObject({ ok: false, errorKind: "forbidden" })

      const authorized = await post(port, "/healthz", {}, { "x-hermes-sidecar-token": token })
      expect(authorized.status).toBe(200)
      expect(authorized.body).toMatchObject({ ok: true })
      const health = authorized.body.result as Record<string, unknown>
      expect(health.connected).toBe(false)
      expect(health.connectRetryInitialMs).toBe(100)
      expect(health.connectRetryMaxMs).toBe(100)
      expect(Number(health.connectAttempts)).toBeGreaterThanOrEqual(1)
      expect(typeof health.connecting).toBe("boolean")

      const sendBeforeReady = await post(port, "/send", {
        target: { chatId: "123" },
        text: "hello",
      }, { "x-hermes-sidecar-token": token })
      expect(sendBeforeReady.status).toBe(503)
      expect(sendBeforeReady.body).toMatchObject({
        ok: false,
        errorKind: "transient",
      })

      const malformed = await postRaw(port, "/shutdown", "{", {
        "x-hermes-sidecar-token": token,
      })
      expect(malformed.status).toBe(400)
      expect(malformed.body).toMatchObject({
        ok: false,
        errorKind: "bad_format",
        error: "invalid JSON request body",
      })
    } finally {
      await post(port, "/shutdown", {}, { "x-hermes-sidecar-token": token }).catch(() => undefined)
      sidecar.kill("SIGTERM")
      await waitForExit(sidecar, 2_000)
    }
  })

  it("serves outbound and lookup endpoints with a connected mock SDK", async () => {
    const dir = await tempDir()
    const outdir = path.join(dir, "bundle")
    buildSidecarBundle(outdir)

    const port = await getOpenPort()
    const token = "runtime-token"
    const sidecar = spawn(process.execPath, [path.join(outdir, "index.mjs")], {
      cwd: dir,
      env: {
        ...process.env,
        INLINE_TOKEN: "fake-inline-token",
        INLINE_BASE_URL: "http://user:pass@127.0.0.1/mock-inline?token=query-secret&safe=1",
        INLINE_SIDECAR_TOKEN: token,
        INLINE_SIDECAR_PORT: String(port),
        INLINE_SIDECAR_BIND: "127.0.0.1",
        INLINE_STATE_PATH: path.join(dir, "state.json"),
        INLINE_SIDECAR_TEST_MOCK: "1",
        INLINE_SIDECAR_TEST_ALLOW_MOCK: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    const logs = collectOutput(sidecar)

    const auth = { "x-hermes-sidecar-token": token }
    try {
      await waitForConnected(port, token, sidecar, logs)

      const health = await post(port, "/healthz", {}, auth)
      expect(health.status).toBe(200)
      expect(health.body).toMatchObject({
        ok: true,
        result: {
          connected: true,
          meId: "999",
          baseUrl: "http://redacted:redacted@127.0.0.1/mock-inline?token=redacted&safe=1",
        },
      })
      expect(JSON.stringify(health.body)).not.toContain("query-secret")
      expect(JSON.stringify(health.body)).not.toContain("user:pass")

      const sent = await post(port, "/send", {
        target: { chatId: "123" },
        text: "hello",
        replyToMsgId: "7",
        parseMarkdown: false,
        actions: {
          rows: [{
            actions: [{ id: "ok", text: "OK", callback: "ok" }],
          }],
        },
      }, auth)
      expect(sent.status).toBe(200)
      expect(resultOf(sent.body)).toMatchObject({ messageId: "9001" })

      const media = await post(port, "/send", {
        target: { userId: "42" },
        text: "caption",
        media: { kind: "photo", photoId: "701" },
      }, auth)
      expect(media.status).toBe(200)
      expect(resultOf(media.body)).toMatchObject({ messageId: "9002" })

      await expectOk(post(port, "/edit", {
        target: { chatId: "123" },
        messageId: "9001",
        text: "updated",
      }, auth))
      await expectOk(post(port, "/delete", {
        target: { chatId: "123" },
        messageId: "9001",
      }, auth))
      await expectOk(post(port, "/typing", {
        target: { chatId: "123" },
        state: "start",
      }, auth))
      await expectOk(post(port, "/presence", {
        target: { userId: "42" },
        kind: "running",
        comment: "working",
      }, auth))

      const photoPath = path.join(dir, "photo.png")
      await writeFile(photoPath, Buffer.from("fake image"))
      const attachment = await post(port, "/send-attachment", {
        target: { chatId: "123" },
        path: photoPath,
        kind: "photo",
        caption: "attached",
        replyToMsgId: "8",
        mimeType: "image/png",
      }, auth)
      expect(attachment.status).toBe(200)
      expect(resultOf(attachment.body)).toMatchObject({
        messageId: "9003",
        fileUniqueId: "mock-file-7001",
      })

      const chat = await post(port, "/chat", { target: { chatId: "123" } }, auth)
      expect(chat.status).toBe(200)
      expect(resultOf(chat.body)).toMatchObject({
        chatId: "123",
        title: "Mock chat 123",
        pinnedMessageIds: ["8801"],
        anchorMessage: expect.objectContaining({ id: "8801", message: "mock pinned message" }),
      })

      const replyThread = await post(port, "/chat", { target: { chatId: "456" } }, auth)
      expect(replyThread.status).toBe(200)
      expect(resultOf(replyThread.body)).toMatchObject({
        chatId: "456",
        title: "Mock reply thread 456",
        parentChatId: "123",
        parentMessageId: "9001",
        untitled: true,
        pinnedMessageIds: ["8801"],
      })

      const messages = await post(port, "/messages", {
        target: { chatId: "123" },
        messageIds: ["9001"],
      }, auth)
      expect(messages.status).toBe(200)
      expect(resultOf(messages.body).messages).toEqual([
        expect.objectContaining({ id: "9001", message: "mock message 9001" }),
      ])

      const history = await post(port, "/history", {
        target: { chatId: "123" },
        limit: 1,
      }, auth)
      expect(history.status).toBe(200)
      expect(resultOf(history.body).messages).toEqual([
        expect.objectContaining({ id: "8801", message: "mock history" }),
      ])

      const search = await post(port, "/search", {
        target: { chatId: "123" },
        query: "deploy",
        limit: 2,
        offsetId: "8801",
      }, auth)
      expect(search.status).toBe(200)
      expect(resultOf(search.body).messages).toEqual([
        expect.objectContaining({ id: "8802", message: "mock search deploy" }),
      ])

      const addReaction = await post(port, "/reaction", {
        target: { chatId: "123" },
        messageId: "9001",
        emoji: "ok",
      }, auth)
      expect(addReaction.status).toBe(200)
      expect(resultOf(addReaction.body)).toMatchObject({ messageId: "9001", emoji: "ok", removed: false })

      const removeReaction = await post(port, "/reaction", {
        target: { chatId: "123" },
        messageId: "9001",
        emoji: "ok",
        remove: true,
      }, auth)
      expect(removeReaction.status).toBe(200)
      expect(resultOf(removeReaction.body)).toMatchObject({ messageId: "9001", emoji: "ok", removed: true })

      const reactions = await post(port, "/reactions", {
        target: { chatId: "123" },
        messageId: "9001",
      }, auth)
      expect(reactions.status).toBe(200)
      expect(resultOf(reactions.body).reactions).toMatchObject({
        reactions: [expect.objectContaining({ emoji: "ok", userId: "222" })],
      })

      const pin = await post(port, "/pin", {
        target: { chatId: "123" },
        messageId: "9001",
      }, auth)
      expect(pin.status).toBe(200)
      expect(resultOf(pin.body)).toMatchObject({ messageId: "9001", unpinned: false })

      const unpin = await post(port, "/pin", {
        target: { chatId: "123" },
        messageId: "9001",
        unpin: true,
      }, auth)
      expect(unpin.status).toBe(200)
      expect(resultOf(unpin.body)).toMatchObject({ messageId: "9001", unpinned: true })

      const pins = await post(port, "/pins", {
        target: { chatId: "123" },
      }, auth)
      expect(pins.status).toBe(200)
      expect(resultOf(pins.body)).toMatchObject({
        chatId: "123",
        pinnedMessageIds: ["8801"],
        anchorMessage: expect.objectContaining({ id: "8801" }),
      })

      const subthread = await post(port, "/create-subthread", {
        parentChatId: "123",
        parentMessageId: "9001",
        title: "Spec thread",
      }, auth)
      expect(subthread.status).toBe(200)
      expect(resultOf(subthread.body)).toMatchObject({ chatId: "321" })

      await expectOk(post(port, "/answer-action", {
        interactionId: "77",
        toast: "Recorded",
      }, auth))

      const finalHealth = await post(port, "/healthz", {}, auth)
      const diagnostics = resultOf(finalHealth.body).diagnostics
      const callsJson = JSON.stringify(diagnostics)
      expect(callsJson).toContain("sendMessage")
      expect(callsJson).toContain("uploadFile")
      expect(callsJson).toContain("getChat")
      expect(callsJson).toContain("getMessages")
      expect(callsJson).toContain("answerMessageAction")
      expect(callsJson).toContain("invoke:GET_CHAT")
      expect(callsJson).toContain("invoke:GET_CHAT_HISTORY")
      expect(callsJson).toContain("invokeUncheckedRaw:SEARCH_MESSAGES")
      expect(callsJson).toContain("invokeUncheckedRaw:ADD_REACTION")
      expect(callsJson).toContain("invokeUncheckedRaw:DELETE_REACTION")
      expect(callsJson).toContain("invokeUncheckedRaw:PIN_MESSAGE")
      expect(callsJson).toContain("invokeUncheckedRaw:CREATE_SUBTHREAD")
    } finally {
      await post(port, "/shutdown", {}, auth).catch(() => undefined)
      sidecar.kill("SIGTERM")
      await waitForExit(sidecar, 2_000)
    }
  })

  it("rejects attachments over the configured upload cap before reading them", async () => {
    const dir = await tempDir()
    const outdir = path.join(dir, "bundle")
    buildSidecarBundle(outdir)

    const port = await getOpenPort()
    const token = "runtime-token"
    const sidecar = spawn(process.execPath, [path.join(outdir, "index.mjs")], {
      cwd: dir,
      env: {
        ...process.env,
        INLINE_TOKEN: "fake-inline-token",
        INLINE_BASE_URL: "http://127.0.0.1/mock-inline",
        INLINE_SIDECAR_TOKEN: token,
        INLINE_SIDECAR_PORT: String(port),
        INLINE_SIDECAR_BIND: "127.0.0.1",
        INLINE_STATE_PATH: path.join(dir, "state.json"),
        INLINE_UPLOAD_MAX_MB: "0.000001",
        INLINE_SIDECAR_TEST_MOCK: "1",
        INLINE_SIDECAR_TEST_ALLOW_MOCK: "1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    })
    const logs = collectOutput(sidecar)
    const auth = { "x-hermes-sidecar-token": token }

    try {
      await waitForConnected(port, token, sidecar, logs)

      const relativePath = await post(port, "/send-attachment", {
        target: { chatId: "123" },
        path: "relative.bin",
        kind: "document",
      }, auth)
      expect(relativePath.status).toBe(400)
      expect(relativePath.body).toMatchObject({
        ok: false,
        errorKind: "bad_format",
      })

      const directoryPath = await post(port, "/send-attachment", {
        target: { chatId: "123" },
        path: dir,
        kind: "document",
      }, auth)
      expect(directoryPath.status).toBe(400)
      expect(directoryPath.body).toMatchObject({
        ok: false,
        errorKind: "bad_format",
      })

      const filePath = path.join(dir, "too-large.bin")
      await writeFile(filePath, Buffer.from("abcd"))
      const response = await post(port, "/send-attachment", {
        target: { chatId: "123" },
        path: filePath,
        kind: "document",
      }, auth)
      expect(response.status).toBe(413)
      expect(response.body).toMatchObject({
        ok: false,
        errorKind: "too_long",
      })
      expect(JSON.stringify(response.body)).toContain("attachment exceeds Inline upload cap")

      const health = await post(port, "/healthz", {}, auth)
      const callsJson = JSON.stringify(resultOf(health.body).diagnostics)
      expect(callsJson).not.toContain("uploadFile")
    } finally {
      await post(port, "/shutdown", {}, auth).catch(() => undefined)
      sidecar.kill("SIGTERM")
      await waitForExit(sidecar, 2_000)
    }
  })
})

function buildSidecarBundle(outdir: string) {
  const built = spawnSync("bun", [
    "build",
    "./src/sidecar/index.ts",
    "--outdir",
    outdir,
    "--entry-naming",
    "index.mjs",
    "--target=node",
    "--format=esm",
    "--packages=bundle",
  ], { cwd: packageRoot, encoding: "utf8" })
  expect(built.status, built.stderr || built.stdout).toBe(0)
}

async function tempDir(): Promise<string> {
  const dir = await mkdtemp(path.join(os.tmpdir(), "inline-hermes-sidecar-"))
  dirs.push(dir)
  return dir
}

function getOpenPort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const address = server.address()
      const port = typeof address === "object" && address ? address.port : 0
      server.close((error) => {
        if (error) reject(error)
        else resolve(port)
      })
    })
  })
}

function collectOutput(child: ChildProcessWithoutNullStreams): () => string {
  const chunks: string[] = []
  child.stdout.on("data", (chunk) => chunks.push(String(chunk)))
  child.stderr.on("data", (chunk) => chunks.push(String(chunk)))
  return () => chunks.join("")
}

async function waitForHttp(port: number, sidecar: ChildProcessWithoutNullStreams, logs: () => string): Promise<void> {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    if (sidecar.exitCode != null) {
      throw new Error(`sidecar exited with code ${sidecar.exitCode}\n${logs()}`)
    }
    try {
      await post(port, "/healthz", {}, {})
      return
    } catch {
      await sleep(100)
    }
  }
  throw new Error("sidecar did not start listening")
}

async function waitForConnected(port: number, token: string, sidecar: ChildProcessWithoutNullStreams, logs: () => string): Promise<void> {
  const deadline = Date.now() + 5_000
  while (Date.now() < deadline) {
    if (sidecar.exitCode != null) {
      throw new Error(`sidecar exited with code ${sidecar.exitCode}\n${logs()}`)
    }
    try {
      const health = await post(port, "/healthz", {}, { "x-hermes-sidecar-token": token })
      if (health.status === 200 && resultOf(health.body).connected === true) return
    } catch {
      await sleep(100)
    }
  }
  throw new Error("sidecar did not connect")
}

async function expectOk(promise: Promise<{ status: number; body: Record<string, unknown> }>): Promise<void> {
  const response = await promise
  expect(response.status).toBe(200)
  expect(response.body).toMatchObject({ ok: true })
}

function resultOf(body: Record<string, unknown>): Record<string, unknown> {
  const result = body.result
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new Error(`missing result object: ${JSON.stringify(body)}`)
  }
  return result as Record<string, unknown>
}

function post(
  port: number,
  requestPath: string,
  body: unknown,
  headers: Record<string, string | string[]>,
): Promise<{ status: number; body: Record<string, unknown> }> {
  return postRaw(port, requestPath, JSON.stringify(body), headers)
}

function postRaw(
  port: number,
  requestPath: string,
  payload: string,
  headers: Record<string, string | string[]>,
): Promise<{ status: number; body: Record<string, unknown> }> {
  return new Promise((resolve, reject) => {
    const req = http.request({
      hostname: "127.0.0.1",
      port,
      path: requestPath,
      method: "POST",
      headers: {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(payload),
        ...headers,
      },
    }, (res) => {
      const chunks: Buffer[] = []
      res.on("data", (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)))
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8")
        try {
          const parsed = text ? JSON.parse(text) as Record<string, unknown> : {}
          resolve({ status: res.statusCode ?? 0, body: parsed })
        } catch (error) {
          reject(error)
        }
      })
    })
    req.on("error", reject)
    req.setTimeout(2_000, () => req.destroy(new Error(`${requestPath} timed out`)))
    req.end(payload)
  })
}

function waitForExit(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<boolean> {
  if (child.exitCode != null) return Promise.resolve(true)
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      cleanup()
      resolve(false)
    }, timeoutMs)
    const onExit = () => {
      cleanup()
      resolve(true)
    }
    const cleanup = () => {
      clearTimeout(timer)
      child.off("exit", onExit)
    }
    child.once("exit", onExit)
  })
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}
