import { describe, expect, it } from "bun:test"
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"

const installer = resolve(import.meta.dir, "install-hermes-host.sh")

async function installFixture({ lock = true, failSync = false, relative = false } = {}) {
  const directory = await realpath(await mkdtemp(join(tmpdir(), "inline-hermes-installer-")))
  const source = join(directory, "upstream")
  const bin = join(directory, "bin")
  const host = join(directory, "host")
  const calls = join(directory, "calls")
  const output = join(directory, "output")
  const executable = async (file: string, body: string) => {
    await writeFile(file, `#!/bin/bash\nset -euo pipefail\n${body}\n`)
    await chmod(file, 0o700)
  }
  try {
    await mkdir(source)
    await mkdir(bin)
    await writeFile(join(source, ".python-version"), "3.14\n")
    await writeFile(join(source, "pyproject.toml"), '[tool.uv]\noverride-dependencies = ["Pillow==13.0.0"]\n')
    if (lock) await writeFile(join(source, "uv.lock"), "version = 1\n")
    await writeFile(calls, "")
    await executable(join(bin, "git"), `
if [[ "$1" == clone ]]; then /bin/cp -R "$HERMES_TEST_SOURCE" "\${@: -1}"
elif [[ "$1" == -C && "$3 $4" == 'rev-parse HEAD' ]]; then printf '%040d\\n' 1
else exit 90; fi`)
    await executable(join(bin, "bootstrap-python"), `
if [[ "$1 $2" != '-m venv' ]]; then exit 91; fi
/bin/mkdir -p "$3/bin"
/bin/cp "$HERMES_TEST_BIN/bootstrap-pip" "$3/bin/python"
/bin/cp "$HERMES_TEST_BIN/uv" "$3/bin/uv"`)
    await executable(join(bin, "bootstrap-pip"), `
[[ "$*" == '-m pip install uv==0.12.19' ]] || exit 92`)
    await executable(join(bin, "uv"), `
printf '%s|%s\\n' "\${UV_PROJECT_ENVIRONMENT:-}" "$*" >> "$HERMES_TEST_CALLS"
if [[ "$1" == venv ]]; then
  /bin/mkdir -p "$4/bin"
  /bin/cp "$HERMES_TEST_BIN/hermes" "$4/bin/hermes"
elif [[ "$1" == sync ]]; then
  if [[ "$HERMES_TEST_FAIL_SYNC" == true ]]; then exit 17; fi
elif [[ "$1 $2" != 'pip install' ]]; then exit 93; fi`)
    await executable(join(bin, "hermes"), `
printf 'hermes-version|%s\\n' "$*" >> "$HERMES_TEST_CALLS"
printf 'Hermes fixture\\n'`)
    const result = Bun.spawnSync(["bash", installer, relative ? "host" : host, "main"], {
      cwd: directory,
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, PYTHON_BIN: join(bin, "bootstrap-python"),
        HERMES_TEST_SOURCE: source, HERMES_TEST_BIN: bin, HERMES_TEST_CALLS: calls,
        HERMES_TEST_FAIL_SYNC: String(failSync), GITHUB_OUTPUT: output },
    })
    return { code: result.exitCode, error: result.stderr.toString(), calls: await readFile(calls, "utf8"),
      output: result.exitCode === 0 ? await readFile(output, "utf8") : "", host }
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
}

describe("official Hermes installer", () => {
  it("syncs upstream's locked project and its overrides into the selected host environment", async () => {
    const result = await installFixture()
    expect(result.code, result.error).toBe(0)
    expect(result.calls).toContain(`${result.host}/venv|sync --project ${result.host}/source --locked --no-dev --python 3.14`)
    expect(result.calls).not.toContain("pip install")
    expect(result.calls).toContain("hermes-version|--version")
    expect(result.output).toContain(`python-bin=${result.host}/venv/bin/python`)
    expect(result.output).toContain("host-ref=main")
  })

  it("retains editable installation for older tags without a uv lock", async () => {
    const result = await installFixture({ lock: false })
    expect(result.code, result.error).toBe(0)
    expect(result.calls).toContain(`|pip install --python ${result.host}/venv/bin/python -e ${result.host}/source`)
    expect(result.calls).not.toContain("|sync ")
  })

  it("keeps a relative destination outside the upstream project", async () => {
    const result = await installFixture({ relative: true })
    expect(result.code, result.error).toBe(0)
    expect(result.calls).toContain(`${result.host}/venv|sync --project ${result.host}/source`)
    expect(result.output).toContain(`hermes-bin=${result.host}/venv/bin/hermes`)
  })

  it("does not bypass a failed locked sync or report the host as installed", async () => {
    const result = await installFixture({ failSync: true })
    expect(result.code).toBe(17)
    expect(result.calls).not.toContain("pip install")
    expect(result.calls).not.toContain("hermes-version")
    expect(result.output).toBe("")
  })
})
