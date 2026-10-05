import { readFile, realpath, stat, writeFile } from "node:fs/promises"
import { basename } from "node:path"
import { setTimeout as pause } from "node:timers/promises"
import { ProviderConnection } from "./socket.js"
import { TranscriptionError, type FinalTurn } from "./protocol.js"

// Controlled short-file smoke only. No RTC connection, Inline posting, VAD or automatic dotenv load.
async function main(): Promise<void> {
  const args = process.argv.slice(2)
  if (args.length === 1 && args[0] === "--help") {
    process.stdout.write("qualify --model standard|meeting --pcm audio.pcm [--out fresh-result.json]\nPCM must be signed16LE mono at 24k Standard / 16k Meeting, 100ms–12s.\n")
    return
  }
  if (args.length !== 4 && args.length !== 6) throw new TranscriptionError("protocol")
  const flags = new Map<string, string>()
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i]!
    const value = args[i + 1]!
    if (!["--model", "--pcm", "--out"].includes(name) || flags.has(name)) throw new TranscriptionError("protocol")
    flags.set(name, value)
  }
  const model = flags.get("--model")
  if (model !== "standard" && model !== "meeting") throw new TranscriptionError("protocol")
  const out = flags.get("--out")
  if (out && (basename(out).startsWith(".env") || !out.endsWith(".json"))) throw new TranscriptionError("protocol")
  const pcmPath = flags.get("--pcm")
  if (!pcmPath || basename(pcmPath).startsWith(".env") || !pcmPath.endsWith(".pcm")) throw new TranscriptionError("audio")
  const resolved = await realpath(pcmPath)
  if (basename(resolved).startsWith(".env") || !resolved.endsWith(".pcm")) throw new TranscriptionError("audio")
  const sampleRate = model === "standard" ? 24_000 : 16_000
  const size = (await stat(resolved)).size
  if (size % 2 !== 0 || size < sampleRate * 2 / 10 || size > sampleRate * 2 * 12) throw new TranscriptionError("audio")
  const bytes = await readFile(resolved)
  // Recheck after the read in case the caller replaced/resized the lab file.
  if (bytes.length !== size) throw new TranscriptionError("audio")
  const samples = new Int16Array(bytes.length / 2)
  for (let i = 0; i < samples.length; i++) samples[i] = bytes.readInt16LE(i * 2)
  const key = process.env[model === "standard" ? "GRID_TRANSCRIPTION_OPENAI_API_KEY" : "GRID_TRANSCRIPTION_SONIOX_API_KEY"]
  if (!key) throw new TranscriptionError("provider")
  const deadline = performance.now() + 40_000
  let resolveFinal!: (turn: FinalTurn) => void
  let rejectFinal!: (error: Error) => void
  const final = new Promise<FinalTurn>((resolve, reject) => { resolveFinal = resolve; rejectFinal = reject })
  // A connection failure may arrive before the caller starts awaiting the final.
  void final.catch(() => {})
  let connection: ProviderConnection | undefined
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    connection = await ProviderConnection.connect({ model, apiKey: key,
      assertAuthority: () => { if (performance.now() >= deadline) throw new TranscriptionError("expired") },
      onFinal: resolveFinal, onFailure: rejectFinal })
    const frameSamples = sampleRate / 50
    for (let offset = 0; offset < samples.length; offset += frameSamples) {
      connection.appendAudio(samples.subarray(offset, offset + frameSamples))
      await pause(20)
    }
    const committedAt = performance.now()
    connection.commitTurn("controlled-file")
    timer = setTimeout(() => { connection?.close(); rejectFinal(new TranscriptionError("provider")) }, 15_000)
    const turn = await final
    if (out) {
      // Explicit optional local lab artifact only; never overwrite an existing file or log text.
      await writeFile(out, JSON.stringify({ model, text: turn.text }, null, 2) + "\n", { flag: "wx", mode: 0o600 })
    }
    process.stdout.write(JSON.stringify({ ok: true, model, audioMs: samples.length * 1000 / sampleRate,
      finalizeMs: Math.round(performance.now() - committedAt), characters: turn.text.length }) + "\n")
  } finally { clearTimeout(timer); connection?.close() }
}

void main().catch((error: unknown) => {
  const code = error instanceof TranscriptionError ? error.code : "qualification"
  process.stderr.write(JSON.stringify({ ok: false, error: code }) + "\n")
  process.exitCode = 1
})
