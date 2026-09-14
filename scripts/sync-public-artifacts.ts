import { copyFile, readFile } from "node:fs/promises"
import { resolve } from "node:path"

// The schema lives in proto/. Cargo keeps a copy for standalone crate builds.
const root = resolve(import.meta.dir, "..")
const source = resolve(root, "proto/core.proto")
const destination = resolve(root, "crates/protocol/proto/core.proto")
if (process.argv.includes("--check")) {
  const [canonical, packaged] = await Promise.all([readFile(source), readFile(destination)])
  if (!canonical.equals(packaged)) throw new Error("Run bun run proto:sync-rust to update the Rust schema copy")
} else {
  await copyFile(source, destination)
  console.log("Updated crates/protocol/proto/core.proto from proto/core.proto")
}
