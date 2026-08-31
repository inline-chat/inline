import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

// Local-only: bun run scripts/macos/check-compose-autocomplete-layout.ts
// Compile the actual menu/surface/palette code without the app's database and RTC dependencies.
if (process.platform !== "darwin") {
  throw new Error("Compose layout checks require macOS and the current Xcode SDK.");
}

const root = resolve(import.meta.dir, "../..");
const output = resolve(root, ".tmp/compose-autocomplete-layout");
await mkdir(output, { recursive: true });

const sourcePaths = [
  "apple/InlineMac/Views/Compose/ComposeCompletionSurface.swift",
  "apple/InlineMac/Views/Compose/ComposeAutocompleteMenu.swift",
  "apple/InlineMac/Views/Compose/ComposeEmojiAutocompletePaletteItem.swift",
  "scripts/macos/check-compose-autocomplete-layout.swift",
];
const sources = await Promise.all(sourcePaths.map(async (path) => {
  const source = await readFile(resolve(root, path), "utf8");
  // Only app-module imports are replaced by the fixture's data/row stand-ins.
  return source.replace(/^import (InlineKit|InlineMacUI)\r?\n/gm, "");
}));
const sourcePath = resolve(output, "probe.swift");
const executable = resolve(output, "probe");
await writeFile(sourcePath, sources.join("\n"));

async function run(command: string[], logName: string) {
  const logPath = resolve(output, logName);
  const child = Bun.spawn(command, { cwd: root, stdout: "pipe", stderr: "pipe" });
  const [status, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
  ]);
  await writeFile(logPath, stdout + stderr);
  if (status !== 0) {
    const tail = (await readFile(logPath, "utf8")).trimEnd().split("\n").slice(-40).join("\n");
    throw new Error(`Compose layout check failed (${status}); ${logPath}\n${tail}`);
  }
  return logPath;
}

await run(["xcrun", "swiftc", "-parse-as-library", sourcePath, "-o", executable], "compile.log");
const runLog = await run([executable], "run.log");
console.log((await readFile(runLog, "utf8")).trim());
console.log(`Artifacts retained in ${output}`);
