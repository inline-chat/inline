import { describe, expect, it } from "bun:test"
import { execFileSync, spawnSync } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs"
import os from "node:os"
import path from "node:path"
import { pathToFileURL } from "node:url"

const root = path.resolve(import.meta.dir, "../..")
const installer = path.join(root, "scripts/ci/install-hermes-host.sh")
const realGit = execFileSync("which", ["git"], { encoding: "utf8" }).trim()

// Keep disposable fixtures; no workspace, services or external network is used.
function fixture(repository = "morajabi/hermes-agent", spoofHead = false,
  options: { pm?: "ready" | "incomplete"; pmExit?: number; versionExit?: number; historyExit?: number;
    canonicalExit?: number; conflictingTag?: boolean; relativePython?: boolean } = {}) {
  const scratch = realpathSync(mkdtempSync(path.join(os.tmpdir(), "inline-hermes-installer-")))
  const remote = path.join(scratch, "remote.git")
  execFileSync(realGit, ["init", "--bare", "-q", remote])
  const releaseFiles = [{ name: ".python-version", content: "3.11\n" },
    { name: "pyproject.toml", content: '[project]\nversion = "0.21.4"\n' }]
  const files = [{ name: ".python-version", content: options.pm ? "3.14\n" : "3.11\n" },
    { name: "pyproject.toml", content: `[project]\nversion = "${options.pm ? "0.0.0" : "0.21.4"}"\n` }]
  if (options.pm) {
    files.push({ name: "pm/__init__.py", content: "# PM source fixture\n" })
    if (options.pm === "ready") files.push({ name: "pm/build_env.py", content: "# PM command seam\n" })
  }
  const allFiles = [...releaseFiles, ...files]
  const firstMark = allFiles.length + 1
  const blobs = allFiles.map((file, index) => `blob\nmark :${index + 1}\ndata ${Buffer.byteLength(file.content)}\n${file.content}\n`).join("")
  const releaseEntries = releaseFiles.map((file, index) => `M 100644 :${index + 1} ${file.name}\n`).join("")
  const entries = files.map((file, index) => `M 100644 :${releaseFiles.length + index + 1} ${file.name}\n`).join("")
  execFileSync(realGit, ["-C", remote, "fast-import", "--quiet"], { input: `${blobs}commit refs/heads/main
mark :${firstMark}
committer Fixture <fixture@example.invalid> 1 +0000
data 4
one
${releaseEntries}
commit refs/heads/main
mark :${firstMark + 1}
committer Fixture <fixture@example.invalid> 2 +0000
data 4
two
from :${firstMark}
${entries}
commit refs/heads/main
mark :${firstMark + 2}
committer Fixture <fixture@example.invalid> 3 +0000
data 6
three
from :${firstMark + 1}
${entries}
` })
  const sha = execFileSync(realGit, ["-C", remote, "rev-parse", "main^"], { encoding: "utf8" }).trim()
  const releaseSha = execFileSync(realGit, ["-C", remote, "rev-parse", "main^^"], { encoding: "utf8" }).trim()
  if (!options.pm || repository === "NousResearch/hermes-agent" || options.conflictingTag) {
    execFileSync(realGit, ["-C", remote, "tag", "v2026.9.21", options.conflictingTag ? sha : releaseSha])
  }
  let canonical = remote
  if (options.pm) {
    canonical = path.join(scratch, "canonical.git")
    execFileSync(realGit, ["init", "--bare", "-q", canonical])
    execFileSync(realGit, ["-C", canonical, "fetch", "--no-tags", remote, "refs/heads/main:refs/heads/main"])
    execFileSync(realGit, ["-C", canonical, "tag", "v2026.9.21", releaseSha])
    execFileSync(realGit, ["-C", canonical, "tag", "v99.0.0", "main"])
  }
  const bin = path.join(scratch, "bin")
  mkdirSync(bin)
  const script = (name: string, source: string) => {
    const file = path.join(bin, name)
    writeFileSync(file, `#!/usr/bin/env bash\nset -euo pipefail\n${source}\n`, { mode: 0o755 })
    return file
  }
  const trace = path.join(scratch, "trace")
  mkdirSync(trace)
  const fakePip = script("pip-python", `printf '%s\\n' "$@" > "$TRACE/pip-args"
[[ "$1" == -m && "$2" == pip && "$3" == install && "$4" == uv==0.12.19 ]]`)
  const fakeHermes = script("hermes", `printf '%s\\n' "$@" > "$TRACE/hermes-args"
printf '%s\\n' "$HERMES_HOME" "$HERMES_RUNTIME_DIR" > "$TRACE/hermes-state"
[[ "$1" == --version ]]
exit "$VERSION_EXIT"`)
  const fakeUv = script("uv", `printf '%s\\n' "$@" > "$TRACE/uv-$1-args"
if [[ "$1" == venv ]]; then
  destination="\${@: -1}"
  mkdir -p "$destination/bin"
  cp "$FAKE_PIP" "$destination/bin/python"
  cp "$FAKE_HERMES" "$destination/bin/hermes"
else
  [[ "$1" == pip && "$2" == install ]]
fi`)
  const bootstrap = script("bootstrap", `printf '%s\\n' "$@" > "$TRACE/bootstrap-args"
if [[ "$1" == -m && "$2" == pm.build_env ]]; then
  printf '%s\\n' "$PWD" > "$TRACE/pm-cwd"
  printf '%s\\n' "$HERMES_HOME" "$HERMES_RUNTIME_DIR" > "$TRACE/pm-state"
  "$REAL_GIT" describe --tags --long --match 'v2[0-9][0-9][0-9].*' HEAD > "$TRACE/pm-description"
  "$REAL_GIT" show v2026.9.21:pyproject.toml > "$TRACE/release-project"
  "$REAL_GIT" tag --merged HEAD --list 'v[0-9]*' > "$TRACE/pm-merged-tags"
  [[ "$PM_EXIT" == 0 ]] || exit "$PM_EXIT"
  [[ "$#" == 6 && "$3" == --source && "$4" == . && "$5" == --out ]]
  [[ ! -e "$6" ]] || { echo 'PM refuses an existing output' >&2; exit 24; }
  mkdir -p "$6/bin"
  cp "$FAKE_PIP" "$6/bin/python"
  cp "$FAKE_HERMES" "$6/bin/hermes"
else
  [[ "$1" == -m && "$2" == venv ]]
  mkdir -p "$3/bin"
  cp "$FAKE_PIP" "$3/bin/python"
  cp "$FAKE_UV" "$3/bin/uv"
fi`)
  script("gh", 'printf "v2026.9.21\\n"')
  if (spoofHead) script("git", `if [[ "$*" == *"rev-parse HEAD" ]]; then
  printf "0000000000000000000000000000000000000000\\n"
else
  exec "$REAL_GIT" "$@"
fi`)
  else if (options.historyExit || options.canonicalExit) script("git", `if [[ "$*" == *"fetch --tags"* && "$HISTORY_EXIT" != 0 ]]; then
  exit "$HISTORY_EXIT"
elif [[ "$*" == *"fetch --no-tags"* && "$CANONICAL_EXIT" != 0 ]]; then
  exit "$CANONICAL_EXIT"
else
  exec "$REAL_GIT" "$@"
fi`)
  const destination = path.join(scratch, "host folder")
  const output = path.join(scratch, "outputs")
  const callerHome = path.join(scratch, "caller home")
  const callerRuntime = path.join(scratch, "caller runtime")
  for (const directory of [callerHome, callerRuntime]) {
    mkdirSync(directory)
    writeFileSync(path.join(directory, "sentinel"), "caller-owned state")
  }
  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    PYTHON_BIN: options.relativePython ? path.relative(root, bootstrap) : bootstrap,
    FAKE_PIP: fakePip, FAKE_UV: fakeUv, FAKE_HERMES: fakeHermes, REAL_GIT: realGit,
    TRACE: trace, PM_EXIT: String(options.pmExit ?? 0), VERSION_EXIT: String(options.versionExit ?? 0),
    HISTORY_EXIT: String(options.historyExit ?? 0),
    CANONICAL_EXIT: String(options.canonicalExit ?? 0),
    HERMES_HOME: callerHome, HERMES_RUNTIME_DIR: callerRuntime,
    GITHUB_OUTPUT: output,
    GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null", GIT_ALLOW_PROTOCOL: "file",
    GIT_CONFIG_COUNT: repository === "NousResearch/hermes-agent" ? "1" : "2",
    GIT_CONFIG_KEY_0: `url.${pathToFileURL(remote).href}.insteadOf`,
    GIT_CONFIG_VALUE_0: `https://github.com/${repository}.git`,
    GIT_CONFIG_KEY_1: `url.${pathToFileURL(canonical).href}.insteadOf`,
    GIT_CONFIG_VALUE_1: "https://github.com/NousResearch/hermes-agent.git",
  }
  return { sha, releaseSha, remote, destination, output, callerHome, callerRuntime,
    called: (name: string) => existsSync(path.join(trace, name)),
    args: (name: string) => readFileSync(path.join(trace, name), "utf8").trimEnd().split("\n"),
    run: (...args: string[]) => spawnSync("bash", [installer, destination, ...args], {
    cwd: root, env, encoding: "utf8", timeout: 15_000,
  }) }
}

describe("Hermes host installation provenance", () => {
  it("fetches the exact reviewed fork commit even when the branch has moved", () => {
    const test = fixture()
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status, result.stderr).toBe(0)
    const head = execFileSync(realGit, ["-C", path.join(test.destination, "source"), "rev-parse", "HEAD"], { encoding: "utf8" }).trim()
    expect(head).toBe(test.sha)
    expect(readFileSync(test.output, "utf8")).toContain(`host-sha=${test.sha}\n`)
    expect(readFileSync(test.output, "utf8")).toContain("host-repository=morajabi/hermes-agent\n")
  })

  for (const ref of ["v2026.9.21", "main", "latest"]) {
    it(`preserves the official ${ref} caller`, () => {
      const test = fixture("NousResearch/hermes-agent")
      const result = test.run(ref)
      expect(result.status, result.stderr).toBe(0)
      expect(test.args("uv-venv-args")).toEqual(["venv", "--python", "3.11", path.join(test.destination, "venv")])
      expect(test.args("uv-pip-args")).toEqual(["pip", "install", "--python",
        path.join(test.destination, "venv/bin/python"), "-e", path.join(test.destination, "source")])
      expect(test.called("pm-state")).toBe(false)
      expect(readFileSync(test.output, "utf8")).toContain("host-repository=NousResearch/hermes-agent\n")
      if (ref !== "main") expect(readFileSync(test.output, "utf8")).toContain(`host-sha=${test.releaseSha}\n`)
    })
  }

  it("rejects empty pins, arbitrary URLs/paths and moving fork refs before installation", () => {
    for (const [ref, repository] of [["", "morajabi/hermes-agent"], ["main", "morajabi/hermes-agent"],
      ["latest", "morajabi/hermes-agent"], ["v2026.9.21", ""], ["main", "https://github.com/morajabi/hermes-agent"],
      ["main", "../hermes-agent"], ["--upload-pack=command", "NousResearch/hermes-agent"]]) {
      const test = fixture()
      const result = test.run(ref!, repository!)
      expect(result.status).not.toBe(0)
      expect(existsSync(path.join(test.destination, "bootstrap"))).toBe(false)
      expect(existsSync(test.output)).toBe(false)
    }
  })

  it("fails unavailable commits without falling back to a branch or installing dependencies", () => {
    const test = fixture()
    const result = test.run("f".repeat(40), "morajabi/hermes-agent")
    expect(result.status).not.toBe(0)
    expect(existsSync(path.join(test.destination, "bootstrap"))).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("checks HEAD equality before starting the Python bootstrap", () => {
    const test = fixture("morajabi/hermes-agent", true)
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain("checkout does not match")
    expect(existsSync(path.join(test.destination, "bootstrap"))).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("refuses to reuse an existing checkout", () => {
    const test = fixture()
    expect(test.run(test.sha, "morajabi/hermes-agent").status).toBe(0)
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain("destination already exists")
  })

  it("builds the exact PM source with frozen defaults and isolated caller-owned state", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", relativePython: true })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status, result.stderr).toBe(0)
    const head = execFileSync(realGit, ["-C", path.join(test.destination, "source"), "rev-parse", "HEAD"], { encoding: "utf8" }).trim()
    expect(head).toBe(test.sha)
    expect(test.args("bootstrap-args")).toEqual(["-m", "pm.build_env", "--source", ".", "--out", path.join(test.destination, "venv")])
    expect(test.args("pm-cwd")).toEqual([path.join(test.destination, "source")])
    expect(test.args("pm-description")[0]).toBe(`v2026.9.21-1-g${test.sha.slice(0, 7)}`)
    expect(test.args("release-project")).toEqual(["[project]", 'version = "0.21.4"'])
    expect(execFileSync(realGit, ["-C", test.remote, "tag", "--list"], { encoding: "utf8" })).toBe("")
    expect(test.args("pm-merged-tags")).toEqual(["v2026.9.21"])
    expect(execFileSync(realGit, ["-C", path.join(test.destination, "source"), "config", "--get", "remote.origin.url"], { encoding: "utf8" }).trim()).toBe("https://github.com/morajabi/hermes-agent.git")
    expect(readFileSync(path.join(test.destination, "source/pyproject.toml"), "utf8")).toContain('version = "0.0.0"')
    expect(existsSync(path.join(test.destination, "source/install-stamp.json"))).toBe(false)
    const isolatedState = [path.join(test.destination, "build-home"), path.join(test.destination, "runtime")]
    expect(test.args("pm-state")).toEqual(isolatedState)
    expect(test.args("hermes-state")).toEqual(isolatedState)
    expect(test.args("hermes-args")).toEqual(["--version"])
    for (const tool of ["pip-args", "uv-venv-args", "uv-pip-args"]) expect(test.called(tool)).toBe(false)
    expect(existsSync(path.join(test.destination, "bootstrap"))).toBe(false)
    for (const directory of [test.callerHome, test.callerRuntime]) {
      expect(readdirSync(directory)).toEqual(["sentinel"])
      expect(readFileSync(path.join(directory, "sentinel"), "utf8")).toBe("caller-owned state")
    }
    expect(readFileSync(test.output, "utf8")).toContain(`host-sha=${test.sha}\n`)
    expect(readFileSync(test.output, "utf8")).toContain(`python-bin=${test.destination}/venv/bin/python\n`)
  })

  it("uses the checked-out PM builder for an official moving main too", () => {
    const test = fixture("NousResearch/hermes-agent", false, { pm: "ready" })
    const result = test.run("main")
    expect(result.status, result.stderr).toBe(0)
    expect(test.args("bootstrap-args")[1]).toBe("pm.build_env")
    expect(test.called("pip-args")).toBe(false)
  })

  it("propagates PM failure without pip fallback, launcher validation or a host receipt", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", pmExit: 23 })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).toBe(23)
    expect(test.called("pm-state")).toBe(true)
    for (const tool of ["pip-args", "uv-venv-args", "uv-pip-args", "hermes-args"]) expect(test.called(tool)).toBe(false)
    expect(existsSync(path.join(test.destination, "bootstrap"))).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("refuses incomplete PM source before any dependency setup", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "incomplete" })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain("PM source is missing")
    expect(test.called("bootstrap-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("stops before PM setup when real source version ancestry cannot be fetched", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", historyExit: 26 })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).toBe(26)
    expect(test.called("bootstrap-args")).toBe(false)
    expect(test.called("hermes-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("withholds PM setup and receipt when canonical release tag acquisition fails", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", canonicalExit: 27 })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).toBe(27)
    expect(test.called("bootstrap-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("rejects conflicting release tags without forcing them or starting PM", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", conflictingTag: true })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).not.toBe(0)
    expect(result.stderr).toContain("would clobber existing tag")
    expect(test.called("bootstrap-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("honors PM refusal of an existing output without changing it or falling back", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready" })
    const output = path.join(test.destination, "venv")
    mkdirSync(output, { recursive: true })
    writeFileSync(path.join(output, "sentinel"), "existing output")
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).toBe(24)
    expect(readFileSync(path.join(output, "sentinel"), "utf8")).toBe("existing output")
    expect(readdirSync(output)).toEqual(["sentinel"])
    expect(test.called("pip-args")).toBe(false)
    expect(test.called("hermes-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })

  it("withholds host outputs when the PM-built launcher fails validation", () => {
    const test = fixture("morajabi/hermes-agent", false, { pm: "ready", versionExit: 25 })
    const result = test.run(test.sha, "morajabi/hermes-agent")
    expect(result.status).toBe(25)
    expect(test.called("hermes-args")).toBe(true)
    expect(test.called("pip-args")).toBe(false)
    expect(existsSync(test.output)).toBe(false)
  })
})
