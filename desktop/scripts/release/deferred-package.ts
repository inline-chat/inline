// INCOMPLETE: Release-design reference only. This is not wired into package
// scripts and does not yet cover dependency setup, staging, signing,
// notarization, updates, or release verification.
import { packager } from "@electron/packager"
import { compileDesktopHost } from "../build"

// Preserved as a release-design reference. Alpha 1 does not expose this as a
// package script until the desktop staging boundary is deliberately designed.
const root = import.meta.dir.replace(/\/scripts\/release$/, "")
const webRoot = `${root}/../web`
const webBuild = Bun.spawn(["bun", "run", "build"], {
  cwd: webRoot,
  stdout: "inherit",
  stderr: "inherit",
})
const webBuildExitCode = await webBuild.exited
if (webBuildExitCode !== 0) {
  throw new Error(`Web build failed with exit code ${webBuildExitCode}`)
}

await compileDesktopHost()

const appPaths = await packager({
  dir: root,
  name: "Inline",
  appVersion: "0.0.0",
  appBundleId: "chat.inline.InlineElectron",
  appCategoryType: "public.app-category.business",
  icon: [
    `${root}/assets/Inline.icns`,
    `${root}/../apple/Icons/InlineAppIcon.icon`,
  ],
  out: `${root}/artifacts/desktop`,
  overwrite: false,
  asar: true,
  prune: false,
  ignore: [
    /^\/(?:src|scripts|build\/.*\.map)(?:\/|$)/,
    /^\/(?:node_modules|artifacts)(?:\/|$)/,
    /^\/(?:AGENTS\.md|tsconfig.*\.json|vite\.config\.ts|vitest\.config\.ts|bun\.lock)(?:\/|$)/,
  ],
})

for (const appPath of appPaths) {
  console.log(appPath)
}
