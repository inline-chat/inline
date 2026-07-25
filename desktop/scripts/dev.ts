import { compileDesktopHost } from "./build"

const root = import.meta.dir.replace(/\/scripts$/, "")
const url = process.env.INLINE_WEB_DEV_URL ?? "http://127.0.0.1:8001"

await compileDesktopHost()

const electron = Bun.spawn(["bun", "electron", "build/main.cjs"], {
  cwd: root,
  env: {
    ...process.env,
    INLINE_WEB_DEV_URL: url,
  },
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
})

const exitCode = await electron.exited
process.exit(exitCode)
