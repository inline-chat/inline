const root = import.meta.dir.replace(/\/tooling$/, "")
const configs = ["tsconfig.json", "tsconfig.tooling.json"]

for (const config of configs) {
  const command = Bun.spawn(["bunx", "tsc", "-p", config, "--noEmit"], {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  })
  const exitCode = await command.exited
  if (exitCode !== 0) process.exit(exitCode)
}

const packages = ["ids", "auth", "client"]
for (const packageName of packages) {
  const command = Bun.spawn(
    ["bun", "run", "typecheck"],
    {
      cwd: `${root}/packages/${packageName}`,
      stdout: "inherit",
      stderr: "inherit",
    },
  )
  const exitCode = await command.exited
  if (exitCode !== 0) process.exit(exitCode)
}
