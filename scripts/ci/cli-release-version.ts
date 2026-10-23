import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";

export function parseCliReleaseTag(tag: string) {
  const number = "(?:0|[1-9][0-9]*)";
  const identifier = `(?:${number}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)`;
  const match = new RegExp(`^cli-v(${number}\\.${number}\\.${number}(?:-${identifier}(?:\\.${identifier})*)?)$`).exec(tag);
  if (!match || tag.trim() !== tag) throw new Error("Expected cli-v followed by canonical SemVer, without build metadata");
  return { tag, version: match[1]!, prerelease: match[1]!.includes("-") };
}

type Cargo = {
  workspace?: { package?: { version?: string }; members?: string[] };
  package?: { name: string; version?: string | { workspace: boolean } };
};

function replaceSectionVersion(contents: string, section: string, version: string): string {
  const escaped = section.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const sectionPattern = new RegExp(`(^\\[${escaped}\\]\\s*\\n)([\\s\\S]*?)(?=^\\[|$(?![\\s\\S]))`, "m");
  let replaced = false;
  const result = contents.replace(sectionPattern, (_match, header: string, body: string) => {
    if (!/^version\s*=\s*"[^"]+"/m.test(body)) throw new Error(`Missing ${section}.version`);
    replaced = true;
    return header + body.replace(/^version\s*=\s*"[^"]+"/m, `version = "${version}"`);
  });
  if (!replaced) throw new Error(`Missing [${section}]`);
  return result;
}

function stampRequirements(contents: string, packages: Set<string>, version: string): string {
  // Internal requirements in this workspace are inline tables. Validate the
  // parsed result below so a future multiline/table form fails closed.
  const result = contents.replace(/^([\w-]+)\s*=\s*\{([^}\n]*)\}/gm, (line, name: string, table: string) => {
    const entry = (Bun.TOML.parse(`entry = {${table}}`) as { entry: { path?: string; package?: string; version?: string } }).entry;
    if (!entry.path || !entry.version || !packages.has(entry.package ?? name)) return line;
    return line.replace(/\bversion\s*=\s*"[^"]+"/, `version = "${version}"`);
  });
  const validate = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    for (const [name, entry] of Object.entries(value)) {
      if (!entry || typeof entry !== "object") continue;
      const dependency = entry as { path?: unknown; package?: string; version?: unknown };
      if (dependency.path && dependency.version && packages.has(dependency.package ?? name) && dependency.version !== version) {
        throw new Error(`Unstamped internal dependency ${name}; use an inline Cargo dependency table`);
      }
      validate(entry);
    }
  };
  validate(Bun.TOML.parse(result));
  return result;
}

/** Plan the workspace, internal requirements and lockfile as one version change. */
export async function planCliReleaseVersion(root: string, tag: string) {
  const release = parseCliReleaseTag(tag);
  const workspacePath = join(root, "Cargo.toml");
  const workspaceContents = await readFile(workspacePath, "utf8");
  const workspace = Bun.TOML.parse(workspaceContents) as Cargo;
  const previous = workspace.workspace?.package?.version;
  if (!previous || !workspace.workspace?.members?.includes("cli")) throw new Error("Expected the Inline Cargo workspace");
  const members = await Promise.all(workspace.workspace.members.map(async (member) => {
    if (!/^[\w/-]+$/.test(member) || member.split("/").includes("..")) throw new Error(`Unsupported workspace member ${member}`);
    const file = join(root, member, "Cargo.toml");
    const contents = await readFile(file, "utf8");
    const data = Bun.TOML.parse(contents) as Cargo;
    if (!data.package?.name) throw new Error(`Missing package name in ${file}`);
    return { file, contents, data };
  }));
  const packages = new Set(members.filter(({ data }) => typeof data.package!.version === "object" && data.package!.version.workspace).map(({ data }) => data.package!.name));
  if (!packages.has("inline-cli")) throw new Error("inline-cli must inherit workspace.package.version");
  const edits = new Map<string, string>();
  edits.set(workspacePath, stampRequirements(replaceSectionVersion(workspaceContents, "workspace.package", release.version), packages, release.version));
  for (const member of members) edits.set(member.file, stampRequirements(member.contents, packages, release.version));

  const lockPath = join(root, "Cargo.lock");
  const locked = await readFile(lockPath, "utf8");
  const found = new Set<string>();
  let stampedLock = locked.replace(/^\[\[package\]\]\n[\s\S]*?(?=^\[\[package\]\]|$(?![\s\S]))/gm, (block) => {
    const data = (Bun.TOML.parse(block) as { package: { name: string; version: string; source?: string }[] }).package[0]!;
    if (!packages.has(data.name) || data.source) return block;
    if (found.has(data.name) || (data.version !== previous && data.version !== release.version)) throw new Error(`Unexpected Cargo.lock version for ${data.name}`);
    found.add(data.name);
    return block.replace(/^version = "[^"]+"/m, `version = "${release.version}"`);
  });
  for (const name of packages) {
    if (!found.has(name)) throw new Error(`Missing workspace package ${name} in Cargo.lock`);
    stampedLock = stampedLock.replaceAll(`"${name} ${previous}"`, `"${name} ${release.version}"`);
  }
  edits.set(lockPath, stampedLock);
  return { release, edits };
}

export async function stampCliReleaseVersion(root: string, tag: string) {
  const { release, edits } = await planCliReleaseVersion(root, tag);
  for (const [file, contents] of edits) await writeFile(file, contents);
  return release;
}

export async function verifyCliReleaseVersion(root: string, tag: string) {
  const { release, edits } = await planCliReleaseVersion(root, tag);
  for (const [file, contents] of edits) {
    if (contents !== await readFile(file, "utf8")) throw new Error(`Commit the release version before tagging: ${file}`);
  }
  return release;
}

if (import.meta.main) {
  const [command, tag, directory] = process.argv.slice(2);
  if (!tag || !["parse", "stamp", "verify"].includes(command ?? "")) throw new Error("Usage: cli-release-version.ts <parse|stamp|verify> TAG [WORKSPACE]");
  const release = command === "stamp"
    ? await stampCliReleaseVersion(resolve(directory ?? join(dirname(import.meta.path), "../..")), tag)
    : command === "verify"
    ? await verifyCliReleaseVersion(resolve(directory ?? join(dirname(import.meta.path), "../..")), tag)
    : parseCliReleaseTag(tag);
  console.log(JSON.stringify(release));
}
