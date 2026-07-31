import { lstat, readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const pluginRoot = path.join(root, "plugins", "inline");
const canonicalSkillRoot = path.join(root, "skills", "inline");
const bundledSkillRoot = path.join(pluginRoot, "skills", "inline");

function check(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function readJson(relativePath) {
  const contents = await readFile(path.join(root, relativePath), "utf8");
  return JSON.parse(contents);
}

async function requireRegularFile(relativePath) {
  const metadata = await lstat(path.join(root, relativePath));
  check(metadata.isFile(), `${relativePath} must be a regular file`);
}

async function requirePluginFile(relativePath, field) {
  check(typeof relativePath === "string" && relativePath.startsWith("./"), `${field} must start with ./`);
  const absolutePath = path.resolve(pluginRoot, relativePath);
  check(
    absolutePath.startsWith(`${pluginRoot}${path.sep}`),
    `${field} must stay inside plugins/inline`,
  );
  const metadata = await lstat(absolutePath);
  check(metadata.isFile(), `${field} must reference a regular file`);
}

async function collectFiles(directory, prefix = "") {
  const files = [];
  const entries = await readdir(directory, { withFileTypes: true });

  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (entry.name === ".DS_Store") continue;

    const absolutePath = path.join(directory, entry.name);
    const relativePath = path.join(prefix, entry.name);

    check(!entry.isSymbolicLink(), `${relativePath} must not be a symbolic link`);
    if (entry.isDirectory()) {
      files.push(...(await collectFiles(absolutePath, relativePath)));
    } else if (entry.isFile()) {
      files.push(relativePath);
    }
  }

  return files;
}

async function checkSkillMirror() {
  const canonicalFiles = await collectFiles(canonicalSkillRoot);
  const bundledFiles = await collectFiles(bundledSkillRoot);
  check(
    JSON.stringify(canonicalFiles) === JSON.stringify(bundledFiles),
    "plugins/inline/skills/inline must contain the same files as skills/inline",
  );

  for (const relativePath of canonicalFiles) {
    const [canonical, bundled] = await Promise.all([
      readFile(path.join(canonicalSkillRoot, relativePath)),
      readFile(path.join(bundledSkillRoot, relativePath)),
    ]);
    check(
      canonical.equals(bundled),
      `plugins/inline/skills/inline/${relativePath} differs from skills/inline/${relativePath}`,
    );
  }
}

const marketplace = await readJson(".agents/plugins/marketplace.json");
check(marketplace.name === "inline", "marketplace name must be inline");
check(marketplace.interface?.displayName === "Inline", "marketplace display name must be Inline");
check(Array.isArray(marketplace.plugins), "marketplace plugins must be an array");

const entry = marketplace.plugins.find((plugin) => plugin.name === "inline");
check(entry, "marketplace must contain the inline plugin");
check(entry.source?.source === "local", "inline plugin source must be local");
check(entry.source?.path === "./plugins/inline", "inline plugin path must be ./plugins/inline");
check(entry.policy?.installation === "AVAILABLE", "inline plugin must be available to install");
check(entry.policy?.authentication === "ON_INSTALL", "inline authentication must happen on install");
check(entry.category === "Communication", "inline marketplace category must be Communication");

const manifest = await readJson("plugins/inline/.codex-plugin/plugin.json");
check(manifest.name === entry.name, "plugin and marketplace names must match");
check(/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(manifest.version), "plugin version must be semver");
check(manifest.skills === "./skills/", "plugin skills path must be ./skills/");
check(manifest.mcpServers === "./.mcp.json", "plugin MCP path must be ./.mcp.json");

const pluginInterface = manifest.interface;
for (const field of ["displayName", "shortDescription", "longDescription", "developerName", "category"]) {
  check(typeof pluginInterface?.[field] === "string" && pluginInterface[field].trim(), `${field} is required`);
}
check(Array.isArray(pluginInterface.capabilities), "plugin capabilities must be an array");
check(pluginInterface.capabilities.every((value) => typeof value === "string" && value.trim()), "plugin capabilities must be non-empty strings");
check(Array.isArray(pluginInterface.defaultPrompt), "plugin defaultPrompt must be an array");
check(pluginInterface.defaultPrompt.length <= 3, "plugin defaultPrompt supports at most three prompts");
check(
  pluginInterface.defaultPrompt.every(
    (value) => typeof value === "string" && value.trim() && value.length <= 128,
  ),
  "plugin prompts must be non-empty strings no longer than 128 characters",
);
for (const field of ["websiteURL", "privacyPolicyURL", "termsOfServiceURL"]) {
  check(new URL(pluginInterface[field]).protocol === "https:", `${field} must use HTTPS`);
}
for (const field of ["composerIcon", "logo", "logoDark"]) {
  await requirePluginFile(pluginInterface[field], field);
}

const mcp = await readJson("plugins/inline/.mcp.json");
const server = mcp.mcpServers?.inline;
check(server?.type === "http", "Inline MCP server must use HTTP");
check(server?.url === "https://mcp.inline.chat/mcp/v2", "Inline MCP server URL is incorrect");
check(server?.oauth_resource === "https://mcp.inline.chat", "Inline OAuth resource is incorrect");

for (const relativePath of [
  "plugins/inline/assets/inline.png",
  "plugins/inline/README.md",
  "plugins/inline/skills/inline/SKILL.md",
]) {
  await requireRegularFile(relativePath);
}

const publicMetadata = JSON.stringify({ marketplace, manifest, mcp });
for (const forbidden of ["test_credentials", "asdk_app_v_", "files.openai.com", "[TODO:"]) {
  check(!publicMetadata.includes(forbidden), `plugin metadata must not contain ${forbidden}`);
}

await checkSkillMirror();
console.log("Codex plugin bundle is valid and the Inline skill mirror is current.");
