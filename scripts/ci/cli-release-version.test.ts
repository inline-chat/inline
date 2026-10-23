import { afterEach, describe, expect, test } from "bun:test";
import type { S3Client } from "bun";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { parse } from "yaml";
import { parseCliReleaseTag, stampCliReleaseVersion, verifyCliReleaseVersion } from "./cli-release-version";
import { assertMatchingReleaseReceipt, buildManifest, parseRemoteReleaseTag, planGitHubReleaseUploads, publishStableEntryPoints, writeReleaseObject } from "../release-cli";

const root = resolve(import.meta.dir, "../..");
const directories: string[] = [];
afterEach(async () => { await Promise.all(directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))); });
async function directory() { const value = await mkdtemp(join(tmpdir(), "inline-cli-release-test-")); directories.push(value); return value; }

async function workspace() {
  const dir = await directory();
  const files: Record<string, string> = {
    "Cargo.toml": '[workspace]\nmembers = ["cli", "crates/sdk", "crates/client"]\nresolver = "3"\n[workspace.package]\nversion = "0.7.18"\nedition = "2024"\n[workspace.dependencies]\ninline-sdk = { version = "0.7.18", path = "crates/sdk" }\n',
    "cli/Cargo.toml": '[package]\nname = "inline-cli"\nversion.workspace = true\nedition.workspace = true\n[dependencies]\ninline-sdk = { path = "../crates/sdk" }\n',
    "crates/sdk/Cargo.toml": '[package]\nname = "inline-sdk"\nversion.workspace = true\nedition.workspace = true\n',
    "crates/client/Cargo.toml": '[package]\nname = "inline-client"\nversion = "0.6.3"\nedition.workspace = true\n[dependencies]\ninline-sdk = { version = "0.7.18", path = "../sdk" }\n',
    "cli/src/main.rs": "fn main() {}\n", "crates/sdk/src/lib.rs": "", "crates/client/src/lib.rs": "",
    "cli/package.json": '{"name":"@inline-chat/cli","private":true}\n',
    "Cargo.lock": '# Fixture lockfile\nversion = 4\n\n[[package]]\nname = "inline-cli"\nversion = "0.7.18"\ndependencies = ["inline-sdk"]\n\n[[package]]\nname = "inline-client"\nversion = "0.6.3"\ndependencies = ["inline-sdk"]\n\n[[package]]\nname = "inline-sdk"\nversion = "0.7.18"\n',
  };
  for (const [name, contents] of Object.entries(files)) { await mkdir(join(dir, name, ".."), { recursive: true }); await writeFile(join(dir, name), contents); }
  return { dir, files };
}

describe("CLI tag version stamping", () => {
  test("uses canonical stable and prerelease tags without build metadata", () => {
    for (const version of ["0.8.0", "0.8.0-alpha.1", "0.8.0-beta.2", "0.8.0-next.3", "0.8.0-rc.1"]) {
      expect(parseCliReleaseTag(`cli-v${version}`)).toEqual({ tag: `cli-v${version}`, version, prerelease: version.includes("-") });
    }
    for (const tag of ["v0.8.0", "cli-v01.8.0", "cli-v0.8", "cli-v0.8.0-alpha.01", "cli-v0.8.0+build", "cli-v0.8.0\n", "cli-v0.8.0-", "cli-v0.8.0;echo unsafe"]) {
      expect(() => parseCliReleaseTag(tag)).toThrow();
    }
  });

  for (const version of ["0.8.0", "0.8.0-alpha.1"]) test(`stamps ${version} consistently and keeps a valid locked Cargo workspace`, async () => {
    const { dir, files } = await workspace();
    await stampCliReleaseVersion(dir, `cli-v${version}`);
    const cargo = Bun.TOML.parse(await readFile(join(dir, "Cargo.toml"), "utf8")) as { workspace: { package: { version: string }; dependencies: { "inline-sdk": { version: string } } } };
    expect(cargo.workspace.package.version).toBe(version);
    expect(cargo.workspace.dependencies["inline-sdk"].version).toBe(version);
    const client = Bun.TOML.parse(await readFile(join(dir, "crates/client/Cargo.toml"), "utf8")) as { package: { version: string }; dependencies: { "inline-sdk": { version: string } } };
    expect(client.package.version).toBe("0.6.3");
    expect(client.dependencies["inline-sdk"].version).toBe(version);
    expect(await readFile(join(dir, "cli/package.json"), "utf8")).toBe(files["cli/package.json"]!);
    const lockBefore = await readFile(join(dir, "Cargo.lock"), "utf8");
    const metadata = Bun.spawnSync(["cargo", "metadata", "--no-deps", "--offline", "--locked", "--format-version", "1"], { cwd: dir });
    expect(metadata.exitCode, metadata.stderr.toString()).toBe(0);
    const packages = JSON.parse(metadata.stdout.toString()).packages as { name: string; version: string }[];
    expect(packages.find((entry) => entry.name === "inline-cli")?.version).toBe(version);
    expect(packages.find((entry) => entry.name === "inline-sdk")?.version).toBe(version);
    expect(packages.find((entry) => entry.name === "inline-client")?.version).toBe("0.6.3");
    expect(await readFile(join(dir, "Cargo.lock"), "utf8")).toBe(lockBefore);
    await stampCliReleaseVersion(dir, `cli-v${version}`);
    expect(await readFile(join(dir, "Cargo.lock"), "utf8")).toBe(lockBefore);
  });

  test("rejects an inconsistent lock before modifying the workspace", async () => {
    const { dir, files } = await workspace();
    await writeFile(join(dir, "Cargo.lock"), files["Cargo.lock"]!.replace('name = "inline-sdk"\nversion = "0.7.18"', 'name = "inline-sdk"\nversion = "0.7.17"'));
    await expect(stampCliReleaseVersion(dir, "cli-v0.8.0-alpha.1")).rejects.toThrow("Unexpected Cargo.lock version");
    expect(await readFile(join(dir, "Cargo.toml"), "utf8")).toBe(files["Cargo.toml"]!);
  });

  test("verifies committed CLI versions without repairing mismatched release source", async () => {
    const { dir, files } = await workspace();
    await expect(verifyCliReleaseVersion(dir, "cli-v0.8.0-alpha.1")).rejects.toThrow("Commit the release version");
    expect(await readFile(join(dir, "Cargo.toml"), "utf8")).toBe(files["Cargo.toml"]!);
    await stampCliReleaseVersion(dir, "cli-v0.8.0-alpha.1");
    expect((await verifyCliReleaseVersion(dir, "cli-v0.8.0-alpha.1")).version).toBe("0.8.0-alpha.1");
  });

  test("the hosted stamp command accepts the real workspace and lockfile without changing source", async () => {
    const dir = await directory();
    const original = await readFile(join(root, "Cargo.toml"), "utf8");
    const current = Bun.TOML.parse(original) as { workspace: { members: string[] } };
    for (const name of ["Cargo.toml", "Cargo.lock", ...current.workspace.members.map((member) => `${member}/Cargo.toml`)]) {
      await mkdir(join(dir, name, ".."), { recursive: true });
      await writeFile(join(dir, name), await readFile(join(root, name)));
    }
    const result = Bun.spawnSync([process.execPath, "--no-env-file", join(root, "scripts/ci/cli-release-version.ts"), "stamp", "cli-v0.0.0-next.999", dir]);
    expect(result.exitCode, result.stderr.toString()).toBe(0);
    expect(JSON.parse(result.stdout.toString()).version).toBe("0.0.0-next.999");
    expect(await readFile(join(root, "Cargo.toml"), "utf8")).toBe(original);
    const lock = Bun.TOML.parse(await readFile(join(dir, "Cargo.lock"), "utf8")) as { package: { name: string; version: string }[] };
    expect(lock.package.find((entry) => entry.name === "inline-cli")?.version).toBe("0.0.0-next.999");
    expect(lock.package.find((entry) => entry.name === "inline-client")?.version).toBe("0.6.3");
  });

  test("peels annotated tags and never accepts an absent or other tag", () => {
    const object = "a".repeat(40), commit = "b".repeat(40), tag = "cli-v0.8.0-alpha.1";
    expect(parseRemoteReleaseTag(`${object}\trefs/tags/${tag}\n${commit}\trefs/tags/${tag}^{}\n`, tag)).toBe(commit);
    expect(parseRemoteReleaseTag(`${commit}\trefs/tags/${tag}\n`, tag)).toBe(commit);
    for (const output of ["", `${commit}\trefs/tags/cli-v0.8.0\n`, `broken\trefs/tags/${tag}\n`]) expect(() => parseRemoteReleaseTag(output, tag)).toThrow();
  });
});

function storage(initial: Record<string, string | Uint8Array> = {}) {
  const objects = new Map(Object.entries(initial).map(([key, value]) => [key, typeof value === "string" ? new TextEncoder().encode(value) : value]));
  const writes: string[] = [];
  const client = { file(key: string) { return {
    exists: async () => objects.has(key),
    text: async () => new TextDecoder().decode(objects.get(key)),
    arrayBuffer: async () => objects.get(key)!.slice().buffer,
    write: async (bytes: Uint8Array) => { writes.push(key); objects.set(key, bytes.slice()); },
  }; } } as unknown as S3Client;
  return { objects, writes, client };
}

describe("CLI immutable publication retries", () => {
  test("binds a version to the same source and complete target set", () => {
    const expected = { version: "0.8.0-alpha.1", tag: "cli-v0.8.0-alpha.1", sourceSha: "a".repeat(40), targets: ["a", "b"] };
    assertMatchingReleaseReceipt({ ...expected, targets: ["b", "a"] }, expected);
    for (const actual of [{ ...expected, sourceSha: "b".repeat(40) }, { ...expected, targets: ["a"] }, { ...expected, version: "0.8.0" }, { ...expected, tag: "cli-v0.8.0" }]) expect(() => assertMatchingReleaseReceipt(actual, expected)).toThrow("different source");
  });

  test("skips identical objects and refuses conflicting immutable bytes", async () => {
    const store = storage();
    const bytes = new TextEncoder().encode("qualified archive");
    expect(await writeReleaseObject(store.client, "cli/v0.8.0/archive", bytes, "application/gzip")).toBe(true);
    expect(await writeReleaseObject(store.client, "cli/v0.8.0/archive", bytes, "application/gzip")).toBe(false);
    await expect(writeReleaseObject(store.client, "cli/v0.8.0/archive", new TextEncoder().encode("other build"), "application/gzip")).rejects.toThrow("Refusing to overwrite");
    expect(store.writes).toEqual(["cli/v0.8.0/archive"]);
    expect(store.objects.get("cli/v0.8.0/archive")).toEqual(bytes);
  });

  test("reuses the original published archive and repairs a missing checksum without invoking a build", async () => {
    const releaseDir = await directory();
    const version = "0.8.0-alpha.1", target = "aarch64-apple-darwin";
    const name = `inline-cli-${version}-${target}.tar.gz`, key = `cli/v${version}/${name}`;
    const bytes = new TextEncoder().encode("original signed archive");
    const store = storage({ [key]: bytes });
    const manifest = await buildManifest({ version, tag: `cli-v${version}`, sourceSha: "a".repeat(40), targets: [target], releaseDir }, "https://example.invalid", "cli", store.client);
    const sha = createHash("sha256").update(bytes).digest("hex");
    expect(await readFile(join(releaseDir, name))).toEqual(Buffer.from(bytes));
    expect(manifest.targets[target]).toEqual({ url: `https://example.invalid/${key}`, sha256: sha, size: bytes.length });
    expect(store.writes).toEqual([`${key}.sha256`]);
    expect(new TextDecoder().decode(store.objects.get(`${key}.sha256`))).toBe(`${sha}  ${name}\n`);
    const corrupt = storage({ [key]: bytes, [`${key}.sha256`]: "another checksum" });
    await expect(buildManifest({ version, tag: `cli-v${version}`, sourceSha: "a".repeat(40), targets: [target], releaseDir }, "https://example.invalid", "cli", corrupt.client)).rejects.toThrow("Refusing to overwrite");
    expect(corrupt.writes).toEqual([]);
  });

  test("uploads only missing GitHub assets and blocks conflicts instead of clobbering", () => {
    const expected = new Map([["a.tar.gz", "a".repeat(64)], ["a.tar.gz.sha256", "b".repeat(64)]]);
    expect(planGitHubReleaseUploads([{ name: "a.tar.gz", digest: `sha256:${"a".repeat(64)}` }], expected)).toEqual(["a.tar.gz.sha256"]);
    expect(() => planGitHubReleaseUploads([{ name: "a.tar.gz", digest: `sha256:${"c".repeat(64)}` }], expected)).toThrow("Different existing");
    expect(() => planGitHubReleaseUploads([{ name: "other-release.tar.gz" }], expected)).toThrow("Unexpected existing");
  });

  test("never lets prereleases or an older stable retry change stable entry points", async () => {
    const stable = JSON.stringify({ version: "0.9.0", sourceSha: "b".repeat(40) });
    for (const version of ["0.8.0-alpha.1", "0.8.0-beta.1", "0.8.0-next.1", "0.8.0"]) {
      const store = storage({ "cli/manifest.json": stable, "cli/install.sh": "current installer" });
      await publishStableEntryPoints(store.client, "cli", { version, tag: `cli-v${version}`, sourceSha: "a".repeat(40), targets: [], releaseDir: await directory() });
      expect(store.writes).toEqual([]);
      expect(new TextDecoder().decode(store.objects.get("cli/manifest.json"))).toBe(stable);
      expect(new TextDecoder().decode(store.objects.get("cli/install.sh"))).toBe("current installer");
    }
  });
});

const workflow = parse(await readFile(join(root, ".github/workflows/cli-release.yml"), "utf8")) as any;

describe("CLI release workflow boundaries", () => {
  test("qualifies tags using trusted main before candidate code or environment secrets", () => {
    expect(workflow.on.push.tags).toEqual(["cli-v*"]);
    expect(workflow.concurrency).toMatchObject({ "cancel-in-progress": false, queue: "max" });
    expect(workflow.permissions.contents).toBe("read");
    expect(workflow.jobs.select.steps[0].with.ref).toBe("main");
    const gate = workflow.jobs.select.steps.find((step: any) => step.id === "gate");
    expect(gate.env.RELEASE_SURFACE).toBe("cli");
    expect(gate.run).toContain("node scripts/ci/assert-release-commit.mjs");
    for (const name of ["preflight", "build-linux", "build-macos", "publish"]) expect(workflow.jobs[name].environment).toBe("cli");
    for (const name of ["preflight", "validate", "build-linux", "build-macos", "publish"]) {
      const job = workflow.jobs[name];
      expect([job.needs].flat()).toContain("select");
      expect(job.steps.find((step: any) => step.uses?.startsWith("actions/checkout@")).with.ref).toBe("${{ needs.select.outputs.sha }}");
      expect(job.steps.find((step: any) => step.name === "Verify committed release version").run).toContain("cli-release-version.ts verify");
    }
    for (const job of Object.values(workflow.jobs) as any[]) for (const step of job.steps) if (step.uses) expect(step.uses).toMatch(/@[a-f0-9]{40}$/);
  });

  test("keeps overrides diagnostic-only and builds all five normal release targets", () => {
    const guard = workflow.jobs.select.steps.find((step: any) => step.name === "Require complete normal publication").run;
    for (const options of [{ TARGETS_OVERRIDE: "aarch64-apple-darwin" }, { SKIP_NOTARIZE: "true" }]) {
      const result = Bun.spawnSync(["bash", "-e", "-c", guard], { env: { ...process.env, TARGETS_OVERRIDE: "", SKIP_NOTARIZE: "false", BUILD_ONLY: "false", PREFLIGHT_ONLY: "false", ...options } });
      expect(result.exitCode).not.toBe(0);
    }
    const diagnostic = Bun.spawnSync(["bash", "-e", "-c", guard], { env: { ...process.env, TARGETS_OVERRIDE: "aarch64-apple-darwin", SKIP_NOTARIZE: "true", BUILD_ONLY: "true", PREFLIGHT_ONLY: "false" } });
    expect(diagnostic.exitCode, diagnostic.stderr.toString()).toBe(0);
    expect(workflow.jobs["build-linux"].strategy.matrix.target).toHaveLength(4);
    expect(workflow.jobs["build-macos"].strategy.matrix.target).toEqual(["aarch64-apple-darwin"]);
    expect(workflow.jobs.publish.if).toContain("inputs.build_only != true");
    expect(workflow.jobs.publish.if).toContain("inputs.preflight_only != true");
  });
});
