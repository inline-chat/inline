export const compileDesktopHost = async () => {
  const root = import.meta.dir.replace(/\/scripts$/, "")
  const builds = await Promise.all([
    Bun.build({
      entrypoints: [`${root}/src/main/index.ts`],
      outdir: `${root}/build`,
      naming: "main.cjs",
      target: "node",
      format: "cjs",
      external: ["electron"],
      sourcemap: "linked",
    }),
    Bun.build({
      entrypoints: [`${root}/src/preload/index.ts`],
      outdir: `${root}/build`,
      naming: "preload.cjs",
      target: "node",
      format: "cjs",
      external: ["electron"],
      sourcemap: "linked",
    }),
  ])

  for (const result of builds) {
    if (!result.success) {
      for (const log of result.logs) console.error(log)
      throw new Error("Electron compilation failed")
    }
  }
}

if (import.meta.main) {
  await compileDesktopHost()
}
