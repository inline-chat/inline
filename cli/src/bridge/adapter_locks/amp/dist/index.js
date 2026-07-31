#!/usr/bin/env node

// src/index.ts
import fs from "node:fs";
import path2 from "node:path";
import os from "node:os";
import readline from "node:readline";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";

// src/run-acp.ts
import { AgentSideConnection, ndJsonStream } from "@agentclientprotocol/sdk";

// src/utils.ts
import { WritableStream, ReadableStream } from "node:stream/web";
function nodeToWebWritable(nodeStream) {
  return new WritableStream({
    write(chunk) {
      return new Promise((resolve, reject) => {
        nodeStream.write(Buffer.from(chunk), (err) => {
          if (err)
            reject(err);
          else
            resolve();
        });
      });
    }
  });
}
function nodeToWebReadable(nodeStream) {
  return new ReadableStream({
    start(controller) {
      nodeStream.on("data", (chunk) => controller.enqueue(new Uint8Array(chunk)));
      nodeStream.on("end", () => controller.close());
      nodeStream.on("error", (err) => controller.error(err));
    }
  });
}

// src/server.ts
import {
  RequestError
} from "@agentclientprotocol/sdk";

// src/amp-transport.ts
import { execute } from "@ampcode/sdk";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
var sdkTransport = {
  name: "sdk",
  execute(request) {
    return execute({
      prompt: request.prompt,
      options: buildAmpSdkOptions(request.options),
      signal: request.signal
    });
  }
};
function buildAmpSdkOptions(options) {
  return {
    cwd: options.cwd,
    env: options.env,
    mode: options.mode,
    noArchiveAfterExecute: true,
    dangerouslyAllowAll: options.dangerouslyAllowAll,
    mcpConfig: options.mcpConfig,
    continue: options.continue
  };
}
function buildAmpCliArgs(options) {
  const args = [];
  if (typeof options.continue === "string") {
    args.push("threads", "continue", options.continue);
  } else if (options.continue) {
    args.push("threads", "continue", "--last");
  }
  args.push("--execute", "--stream-json", "--no-archive-after-execute", "--no-ide");
  if (options.mode)
    args.push("--mode", options.mode);
  if (options.dangerouslyAllowAll)
    args.push("--dangerously-allow-all");
  if (options.mcpConfig)
    args.push("--mcp-config", JSON.stringify(options.mcpConfig));
  return args;
}
function createCliTransport(command = process.env.AMP_CLI_PATH ?? "amp", commandArgs = []) {
  return {
    name: "cli",
    async* execute({ prompt, options, signal }) {
      signal.throwIfAborted();
      const child = spawn(command, [...commandArgs, ...buildAmpCliArgs(options)], {
        cwd: options.cwd,
        env: { ...process.env, ...options.env },
        stdio: ["pipe", "pipe", "pipe"]
      });
      const stderr = [];
      child.stderr.on("data", (chunk) => stderr.push(chunk));
      const completion = new Promise((resolve, reject) => {
        child.once("error", reject);
        child.once("close", (code, processSignal) => resolve({ code, processSignal }));
      });
      const abort = () => child.kill(process.platform === "win32" ? "SIGKILL" : "SIGTERM");
      signal.addEventListener("abort", abort, { once: true });
      child.stdin.on("error", () => {});
      child.stdin.end(prompt);
      try {
        const lines = createInterface({ input: child.stdout, crlfDelay: Number.POSITIVE_INFINITY });
        for await (const line of lines) {
          if (!line.trim())
            continue;
          try {
            yield JSON.parse(line);
          } catch {
            throw new Error(`Failed to parse JSON response, raw line: ${line}`);
          }
        }
        const { code, processSignal } = await completion;
        if (signal.aborted)
          throw new Error("Amp CLI process was aborted");
        if (code === null)
          throw new Error(`Amp CLI process was killed by signal ${processSignal ?? "unknown"}`);
        if (code !== 0) {
          const details = Buffer.concat(stderr).toString().trim();
          throw new Error(`Amp CLI process exited with code ${code}${details ? `: ${details}` : ""}`);
        }
      } finally {
        signal.removeEventListener("abort", abort);
        if (!child.killed && child.exitCode === null)
          child.kill();
      }
    }
  };
}
function createAmpTransport(name = process.env.AMP_ACP_TRANSPORT ?? "cli") {
  switch (name) {
    case "sdk":
      return sdkTransport;
    case "cli":
      return createCliTransport();
    default:
      throw new Error(`Unsupported AMP_ACP_TRANSPORT: ${name}`);
  }
}

// src/mcp-config.ts
function convertAcpMcpServersToAmpConfig(mcpServers) {
  const mcpConfig = {};
  if (!Array.isArray(mcpServers)) {
    return mcpConfig;
  }
  for (const server of mcpServers) {
    if ("type" in server) {
      if (server.type === "acp") {
        continue;
      }
      const headers = {};
      for (const header of server.headers) {
        headers[header.name] = header.value;
      }
      mcpConfig[server.name] = {
        url: server.url,
        headers: Object.keys(headers).length > 0 ? headers : undefined
      };
      continue;
    }
    const env = server.env.length > 0 ? Object.fromEntries(server.env.map((entry) => [entry.name, entry.value])) : undefined;
    mcpConfig[server.name] = {
      command: server.command,
      args: server.args,
      env
    };
  }
  return mcpConfig;
}

// src/to-acp.ts
function toAcpNotifications(message, sessionId) {
  const content = message.message?.content;
  if (typeof content === "string") {
    return [
      {
        sessionId,
        update: {
          sessionUpdate: message.type === "assistant" ? "agent_message_chunk" : "user_message_chunk",
          content: { type: "text", text: content }
        }
      }
    ];
  }
  const output = [];
  if (!Array.isArray(content))
    return output;
  for (const chunk of content) {
    let update = null;
    switch (chunk.type) {
      case "text":
        update = {
          sessionUpdate: message.type === "assistant" ? "agent_message_chunk" : "user_message_chunk",
          content: { type: "text", text: chunk.text }
        };
        break;
      case "image":
        update = {
          sessionUpdate: message.type === "assistant" ? "agent_message_chunk" : "user_message_chunk",
          content: {
            type: "image",
            data: chunk.source?.type === "base64" ? chunk.source.data ?? "" : "",
            mimeType: chunk.source?.type === "base64" ? chunk.source.media_type ?? "" : "",
            uri: chunk.source?.type === "url" ? chunk.source.url : undefined
          }
        };
        break;
      case "thinking":
        update = {
          sessionUpdate: "agent_thought_chunk",
          content: { type: "text", text: chunk.thinking }
        };
        break;
      case "tool_use":
        {
          const metadata = toolCallMetadata(chunk.name, chunk.input);
          update = {
            toolCallId: chunk.id,
            sessionUpdate: "tool_call",
            rawInput: safeJson(chunk.input),
            status: "pending",
            title: metadata.title,
            kind: metadata.kind,
            locations: metadata.locations.length > 0 ? metadata.locations : undefined,
            content: []
          };
        }
        break;
      case "tool_result":
        update = {
          toolCallId: chunk.tool_use_id,
          sessionUpdate: "tool_call_update",
          status: chunk.is_error ? "failed" : "completed",
          content: toAcpContentArray(chunk.content, chunk.is_error)
        };
        break;
      default:
        break;
    }
    if (update)
      output.push({ sessionId, update });
  }
  return output;
}
function toAcpContentArray(content, isError = false) {
  if (Array.isArray(content) && content.length > 0) {
    return content.map((c) => ({
      type: "content",
      content: { type: "text", text: isError ? wrapCode(c.text) : c.text }
    }));
  }
  if (typeof content === "string" && content.length > 0) {
    return [{ type: "content", content: { type: "text", text: isError ? wrapCode(content) : content } }];
  }
  return [];
}
function wrapCode(t) {
  return "```\n" + t + "\n```";
}
function toolCallMetadata(name, input) {
  const toolName = name || "Tool";
  const args = isRecord(input) ? input : {};
  const title = toolCallTitle(toolName, args);
  return {
    title,
    kind: toolKind(toolName),
    locations: toolCallLocations(toolName, args)
  };
}
function toolCallTitle(name, input) {
  const command = commandValue(input);
  const path = firstString(input, ["path", "file_path", "notebook_path"]);
  const pattern = stringValue(input.pattern);
  const url = stringValue(input.url);
  switch (name) {
    case "Bash":
      return withDetail(name, command);
    case "Read":
      return withDetail(name, path);
    case "Write":
      return withDetail(name, path);
    case "Edit":
    case "MultiEdit":
      return withDetail(name, path);
    case "Glob":
      return withDetail(name, pattern ?? path);
    case "Grep":
      return withDetail(name, pattern ?? path);
    case "LS":
      return withDetail("List", path);
    case "WebFetch":
      return withDetail(name, url);
    case "TodoWrite":
      return "Update todo list";
    case "Task":
      return withDetail(name, stringValue(input.description) ?? stringValue(input.subagent_type));
    default:
      return withDetail(name, firstScalarString(input));
  }
}
function commandValue(input) {
  return commandSegmentValue(input.cmd) ?? commandSegmentValue(input.command) ?? firstString(input, ["shell_command", "shellCommand", "script"]) ?? nestedCommandValue(input, 0);
}
function commandSegmentValue(value) {
  if (typeof value === "string" && value.length > 0)
    return value;
  if (!Array.isArray(value))
    return;
  const parts = value.filter((v) => typeof v === "string").map((v) => v.trim()).filter((v) => v.length > 0);
  return parts.length > 0 ? parts.join(" ") : undefined;
}
function nestedCommandValue(value, depth) {
  if (!isRecord(value) || depth > 2)
    return;
  const direct = commandSegmentValue(value.cmd) ?? commandSegmentValue(value.command);
  if (direct)
    return direct;
  for (const child of Object.values(value)) {
    if (!isRecord(child))
      continue;
    const nested = nestedCommandValue(child, depth + 1);
    if (nested)
      return nested;
  }
  return;
}
function toolKind(name) {
  switch (name) {
    case "Read":
    case "LS":
      return "read";
    case "Write":
    case "Edit":
    case "MultiEdit":
      return "edit";
    case "Glob":
    case "Grep":
      return "search";
    case "Bash":
      return "execute";
    case "WebFetch":
      return "fetch";
    case "TodoWrite":
    case "Task":
      return "think";
    default:
      return name.startsWith("mcp__") ? "fetch" : "other";
  }
}
function toolCallLocations(name, input) {
  const path = firstString(input, ["path", "file_path", "notebook_path"]);
  if (!path)
    return [];
  switch (name) {
    case "Read":
    case "Write":
    case "Edit":
    case "MultiEdit":
    case "LS":
    case "Grep":
    case "Glob": {
      const line = numberValue(input.line) ?? numberValue(input.offset);
      return line === undefined ? [{ path }] : [{ path, line }];
    }
    default:
      return [];
  }
}
function withDetail(name, detail) {
  if (!detail)
    return name;
  return `${name}: ${truncateSingleLine(detail, 120)}`;
}
function firstString(input, keys) {
  for (const key of keys) {
    const value = stringValue(input[key]);
    if (value)
      return value;
  }
  return;
}
function firstScalarString(input) {
  for (const value of Object.values(input)) {
    const string = stringValue(value) ?? numberValue(value)?.toString() ?? booleanValue(value)?.toString();
    if (string)
      return string;
  }
  return;
}
function stringValue(value) {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
function numberValue(value) {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
}
function booleanValue(value) {
  return typeof value === "boolean" ? value : undefined;
}
function truncateSingleLine(value, maxLength) {
  const singleLine = value.replace(/\s+/g, " ").trim();
  if (singleLine.length <= maxLength)
    return singleLine;
  return `${singleLine.slice(0, maxLength - 1)}…`;
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function safeJson(x) {
  try {
    return JSON.parse(JSON.stringify(x));
  } catch {
    return;
  }
}

// src/server.ts
import path from "node:path";
// package.json
var package_default = {
  name: "amp-acp",
  version: "0.8.1",
  private: false,
  type: "module",
  main: "dist/index.js",
  bin: {
    "amp-acp": "dist/index.js"
  },
  files: [
    "dist"
  ],
  description: "ACP adapter that bridges Amp Code to Agent Client Protocol (Zed external agent)",
  license: "Apache-2.0",
  repository: {
    type: "git",
    url: "https://github.com/tao12345666333/amp-acp"
  },
  scripts: {
    build: "bun build src/index.ts --target=node --outdir=dist --entry-naming=[dir]/[name].js",
    "build:binary": "bun build src/index.ts --target=node --outdir=dist --entry-naming=[dir]/[name].js && bun build dist/index.js --compile --outfile dist/amp-acp",
    start: "bun dist/index.js",
    lint: "tsc --noEmit",
    test: "bun test src/",
    "test:binary": "bun build src/index.ts --target=node --outdir=dist --entry-naming=[dir]/[name].js && bun build dist/index.js --compile --outfile dist/amp-acp-test && bun test test/",
    "test:e2e:real": "bun build src/index.ts --target=node --outdir=dist --entry-naming=[dir]/[name].js && bun build dist/index.js --compile --outfile dist/amp-acp-test && bun test test/acp-real-cli-e2e.test.ts",
    "test:all": "bun run test && bun run test:binary"
  },
  dependencies: {
    "@agentclientprotocol/sdk": "1.2.1",
    "@ampcode/sdk": "0.1.0-20260717152646-g22b5e58"
  },
  devDependencies: {
    "@types/bun": "^1.2.5",
    typescript: "^7.0.2"
  }
};

// src/server.ts
var PACKAGE_VERSION = package_default.version;
var CONFIG_PERMISSION = "permission";
var CONFIG_AMP_MODE = "amp-mode";
var PERMISSION_MODES = ["default", "bypass"];
var AMP_MODELS = [
  {
    modelId: "low",
    name: "Low",
    description: "Fast and economical for simple, well-defined tasks."
  },
  {
    modelId: "medium",
    name: "Medium",
    description: "Balanced capability and cost for everyday coding tasks."
  },
  {
    modelId: "high",
    name: "High",
    description: "Greater capability and reasoning for difficult tasks."
  },
  {
    modelId: "ultra",
    name: "Ultra",
    description: "Maximum capability for the most demanding tasks."
  }
];
function isAmpModelId(modelId) {
  return AMP_MODELS.some((model) => model.modelId === modelId);
}
function isPermissionMode(mode) {
  return PERMISSION_MODES.some((permissionMode) => permissionMode === mode);
}
function buildSessionConfigOptions(s) {
  return [
    {
      type: "select",
      id: CONFIG_PERMISSION,
      name: "Permissions",
      description: "Controls whether Amp uses configured permissions or force-allows tool calls.",
      category: "mode",
      currentValue: s.mode,
      options: [
        {
          value: "default",
          name: "Default",
          description: "Use Amp's configured behavior. As of Amp Neo, tools run without prompts unless you've opted into permissions."
        },
        {
          value: "bypass",
          name: "Bypass",
          description: "Force-allow every tool call, overriding any configured permissions plugin."
        }
      ]
    },
    {
      type: "select",
      id: CONFIG_AMP_MODE,
      name: "Amp Mode",
      description: "Select the Amp execution mode.",
      category: "model",
      currentValue: s.model,
      options: AMP_MODELS.map((model) => ({
        value: model.modelId,
        name: model.name,
        description: model.description
      }))
    }
  ];
}

class AmpAcpAgent {
  client;
  transport;
  sessions = new Map;
  clientCapabilities;
  constructor(client, transport = createAmpTransport()) {
    this.client = client;
    this.transport = transport;
  }
  async initialize(request) {
    this.clientCapabilities = request.clientCapabilities;
    console.info(`[acp] amp-acp v${PACKAGE_VERSION} initialized`);
    return {
      protocolVersion: 1,
      agentInfo: {
        name: "amp-acp",
        title: "Amp ACP Agent",
        version: PACKAGE_VERSION
      },
      agentCapabilities: {
        promptCapabilities: { image: true, embeddedContext: true },
        mcpCapabilities: { http: true, sse: true }
      },
      authMethods: [
        {
          id: "setup",
          name: "Amp API Key Setup",
          description: "Run interactive setup to configure your Amp API key",
          _meta: {
            "terminal-auth": {
              command: getTerminalAuthCommand(),
              args: ["--setup"],
              label: "Amp API Key Setup"
            }
          }
        }
      ]
    };
  }
  async newSession(params) {
    const sessionId = `S-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
    const mcpConfig = convertAcpMcpServersToAmpConfig(params.mcpServers);
    const session = {
      threadId: null,
      controller: null,
      cancelled: false,
      active: false,
      mode: "default",
      model: "medium",
      mcpConfig,
      cwd: params.cwd || process.cwd()
    };
    this.sessions.set(sessionId, session);
    const result = {
      sessionId,
      configOptions: buildSessionConfigOptions(session)
    };
    setImmediate(async () => {
      try {
        await this.client.sessionUpdate({
          sessionId,
          update: {
            sessionUpdate: "available_commands_update",
            availableCommands: [
              {
                name: "init",
                description: "Generate an AGENTS.md file for the project"
              }
            ]
          }
        });
      } catch (e) {
        console.error("[acp] failed to send available_commands_update", e);
      }
    });
    return result;
  }
  async authenticate(_params) {
    if (process.env.AMP_API_KEY) {
      return {};
    }
    throw RequestError.authRequired();
  }
  async prompt(params) {
    const s = this.sessions.get(params.sessionId);
    if (!s)
      throw new Error("Session not found");
    s.cancelled = false;
    s.active = true;
    let textInput = "";
    for (const chunk of params.prompt) {
      switch (chunk.type) {
        case "text":
          if (chunk.text.trim() === "/init") {
            textInput += `Please analyze this codebase and create an AGENTS.md file containing:
1. Build/lint/test commands - especially for running a single test
2. Architecture and codebase structure information, including important subprojects, internal APIs, databases, etc.
3. Code style guidelines, including imports, conventions, formatting, types, naming conventions, error handling, etc.

The file you create will be given to agentic coding tools (such as yourself) that operate in this repository. Make it about 20 lines long.

If there are Cursor rules (in .cursor/rules/ or .cursorrules), Claude rules (CLAUDE.md), Windsurf rules (.windsurfrules), Cline rules (.clinerules), Goose rules (.goosehints), or Copilot rules (in .github/copilot-instructions.md), make sure to include them. Also, first check if there is an existing AGENTS.md or AGENT.md file, and if so, update it instead of overwriting it.`;
          } else {
            textInput += chunk.text;
          }
          break;
        case "resource_link":
          textInput += `
${chunk.uri}
`;
          break;
        case "resource":
          if ("text" in chunk.resource) {
            textInput += `
<context ref="${chunk.resource.uri}">
${chunk.resource.text}
</context>
`;
          }
          break;
        case "image":
          break;
        default:
          break;
      }
    }
    const options = {
      cwd: s.cwd,
      env: { TERM: "dumb" },
      mode: s.model
    };
    if (s.mode === "bypass") {
      options.dangerouslyAllowAll = true;
    }
    if (Object.keys(s.mcpConfig).length > 0) {
      options.mcpConfig = s.mcpConfig;
    }
    if (s.threadId) {
      options.continue = s.threadId;
    } else if (process.env.AMP_ACP_CONTINUE_LATEST) {
      options.continue = true;
      console.error("[acp] AMP_ACP_CONTINUE_LATEST set; continuing latest thread on this installation");
    }
    const controller = new AbortController;
    s.controller = controller;
    try {
      for await (const message of this.transport.execute({ prompt: textInput, options, signal: controller.signal })) {
        if (!s.threadId && message.session_id) {
          s.threadId = message.session_id;
          console.error(`[amp] thread ${s.threadId}`);
        }
        if (message.type === "assistant" || message.type === "user") {
          for (const n of toAcpNotifications(message, params.sessionId)) {
            try {
              await this.client.sessionUpdate(n);
            } catch (e) {
              console.error("[acp] sessionUpdate failed", e);
            }
          }
        }
        if (message.type === "result" && message.is_error) {
          if (typeof message.error === "string" && isAuthError(message.error)) {
            console.error("[amp] Auth error in result, requesting authentication:", message.error);
            throw RequestError.authRequired();
          }
          await this.client.sessionUpdate({
            sessionId: params.sessionId,
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Error: ${message.error}` } }
          });
        }
      }
      return { stopReason: s.cancelled ? "cancelled" : "end_turn" };
    } catch (err) {
      if (s.cancelled || err instanceof Error && (err.name === "AbortError" || err.message.includes("aborted"))) {
        return { stopReason: "cancelled" };
      }
      if (err instanceof Error && isAuthError(err.message)) {
        console.error("[amp] Auth error, requesting authentication:", err.message);
        throw RequestError.authRequired();
      }
      console.error("[amp] Execution error:", err);
      throw err;
    } finally {
      s.active = false;
      s.cancelled = false;
      s.controller = null;
    }
  }
  async cancel(params) {
    const s = this.sessions.get(params.sessionId);
    if (!s)
      return;
    if (s.active && s.controller) {
      s.cancelled = true;
      s.controller.abort();
    }
  }
  async setSessionConfigOption(params) {
    const s = this.sessions.get(params.sessionId);
    if (!s)
      throw new Error("Session not found");
    if (typeof params.value !== "string") {
      throw new Error(`Unsupported value for ${params.configId}`);
    }
    switch (params.configId) {
      case CONFIG_PERMISSION:
        if (!isPermissionMode(params.value)) {
          throw new Error(`Unsupported permission mode: ${params.value}`);
        }
        s.mode = params.value;
        break;
      case CONFIG_AMP_MODE:
        if (!isAmpModelId(params.value)) {
          throw new Error(`Unsupported Amp mode: ${params.value}`);
        }
        s.model = params.value;
        break;
      default:
        throw new Error(`Unsupported config option: ${params.configId}`);
    }
    const configOptions = buildSessionConfigOptions(s);
    try {
      await this.client.sessionUpdate({
        sessionId: params.sessionId,
        update: {
          sessionUpdate: "config_option_update",
          configOptions
        }
      });
    } catch (e) {
      console.error("[acp] failed to send config_option_update", e);
    }
    return { configOptions };
  }
  async setSessionMode(params) {
    const s = this.sessions.get(params.sessionId);
    if (!s)
      throw new Error("Session not found");
    if (!isPermissionMode(params.modeId)) {
      throw new Error(`Unsupported mode: ${params.modeId}`);
    }
    s.mode = params.modeId;
    return {};
  }
  async readTextFile(params) {
    return this.client.readTextFile(params);
  }
  async writeTextFile(params) {
    return this.client.writeTextFile(params);
  }
}
function isAuthError(message) {
  const lower = message.toLowerCase();
  return lower.includes("invalid or missing api key") || lower.includes("run 'amp login'") || lower.includes("authentication") || lower.includes("unauthorized") || lower.includes("no api key found") || lower.includes("api key") && lower.includes("login flow") || lower.includes("api key") && (lower.includes("missing") || lower.includes("invalid"));
}
function getTerminalAuthCommand(argv1 = process.argv[1], execPath = process.execPath) {
  const resolvedArgv1 = argv1 ? path.resolve(argv1) : "";
  if (!resolvedArgv1 || resolvedArgv1.startsWith("/$bunfs/")) {
    return execPath;
  }
  return resolvedArgv1;
}

// src/run-acp.ts
function runAcp() {
  const input = nodeToWebWritable(process.stdout);
  const output = nodeToWebReadable(process.stdin);
  const stream = ndJsonStream(input, output);
  new AgentSideConnection((client) => new AmpAcpAgent(client), stream);
}

// src/index.ts
console.log = console.error;
console.info = console.error;
console.warn = console.error;
console.debug = console.error;
var AMP_CLI_NATIVE_PACKAGES = {
  darwin: {
    arm64: { pkg: "@ampcode/cli-darwin-arm64", bin: "amp" },
    x64: { pkg: "@ampcode/cli-darwin-x64", bin: "amp" }
  },
  linux: {
    arm64: { pkg: "@ampcode/cli-linux-arm64", bin: "amp" },
    x64: { pkg: "@ampcode/cli-linux-x64", bin: "amp" }
  },
  win32: {
    x64: { pkg: "@ampcode/cli-win32-x64", bin: "amp.exe" }
  }
};
function getPlatformArch() {
  let arch = os.arch();
  if (process.platform === "darwin" && arch === "x64") {
    const result = spawnSync("sysctl", ["-n", "sysctl.proc_translated"], { encoding: "utf8" });
    if (result.stdout?.trim() === "1") {
      arch = "arm64";
    }
  }
  return arch;
}
function resolveNativeAmpCliBinary(req) {
  const nativePackage = AMP_CLI_NATIVE_PACKAGES[process.platform]?.[getPlatformArch()];
  if (!nativePackage)
    return;
  const pkgJsonPath = req.resolve(`${nativePackage.pkg}/package.json`);
  const binPath = path2.join(path2.dirname(pkgJsonPath), nativePackage.bin);
  return fs.existsSync(binPath) ? binPath : undefined;
}
function isBrokenAmpCliStub(binPath) {
  try {
    const stat = fs.statSync(binPath);
    if (stat.size >= 4096)
      return false;
    const contents = fs.readFileSync(binPath, "utf8");
    return contents.includes("Amp native binary not installed") || contents.startsWith("echo ");
  } catch {
    return false;
  }
}
function repairAmpCliPackageBin(req) {
  const nativeBinPath = resolveNativeAmpCliBinary(req);
  if (!nativeBinPath)
    return;
  const pkgJsonPath = req.resolve("@ampcode/cli/package.json");
  const pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, "utf-8"));
  if (!pkgJson.bin?.amp)
    return nativeBinPath;
  const binPath = path2.resolve(path2.dirname(pkgJsonPath), pkgJson.bin.amp);
  if (!fs.existsSync(binPath) || isBrokenAmpCliStub(binPath)) {
    fs.copyFileSync(nativeBinPath, binPath);
    if (process.platform !== "win32") {
      fs.chmodSync(binPath, 493);
    }
  }
  return binPath;
}
function preferBundledAmpCliBinary() {
  if (process.env.AMP_CLI_PATH)
    return;
  try {
    const req = createRequire(import.meta.url);
    try {
      const ampCliBin = repairAmpCliPackageBin(req);
      if (ampCliBin) {
        process.env.AMP_CLI_PATH = ampCliBin;
        return;
      }
    } catch {}
    for (const pkg of ["@ampcode/cli", "@sourcegraph/amp"]) {
      try {
        const pkgJsonPath = req.resolve(`${pkg}/package.json`);
        const pkgJson = JSON.parse(fs.readFileSync(pkgJsonPath, "utf-8"));
        if (!pkgJson.bin?.amp)
          continue;
        const binPath = path2.resolve(path2.dirname(pkgJsonPath), pkgJson.bin.amp);
        if (!fs.existsSync(binPath))
          continue;
        if (pkg === "@ampcode/cli" && isBrokenAmpCliStub(binPath))
          continue;
        if (binPath.endsWith(".js") || binPath.endsWith(".mjs") || binPath.endsWith(".cjs"))
          continue;
        process.env.AMP_CLI_PATH = binPath;
        return;
      } catch {}
    }
  } catch {}
}
function getConfigDir() {
  if (process.platform === "win32") {
    return path2.join(process.env.APPDATA ?? path2.join(os.homedir(), "AppData", "Roaming"), "amp-acp");
  }
  return path2.join(process.env.XDG_CONFIG_HOME ?? path2.join(os.homedir(), ".config"), "amp-acp");
}
function getCredentialsPath() {
  return path2.join(getConfigDir(), "credentials.json");
}
function loadStoredApiKey() {
  const credPath = getCredentialsPath();
  try {
    const data = JSON.parse(fs.readFileSync(credPath, "utf-8"));
    return data.apiKey || undefined;
  } catch {
    return;
  }
}
function prompt(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stderr });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}
async function setup() {
  const existing = process.env.AMP_API_KEY || loadStoredApiKey();
  if (existing) {
    console.error("AMP API key is already configured.");
    process.exit(0);
  }
  console.error("You can get your API key from: https://ampcode.com/settings");
  const apiKey = await prompt("Paste your AMP API key: ");
  if (!apiKey) {
    console.error("No API key provided. Aborting.");
    process.exit(1);
  }
  const configDir = getConfigDir();
  fs.mkdirSync(configDir, { recursive: true });
  const credPath = getCredentialsPath();
  fs.writeFileSync(credPath, JSON.stringify({ apiKey }, null, 2) + `
`, { mode: 384 });
  console.error(`API key saved to ${credPath}`);
  process.exit(0);
}
if (process.argv.includes("--setup")) {
  await setup();
} else {
  if (!process.env.AMP_API_KEY) {
    const stored = loadStoredApiKey();
    if (stored) {
      process.env.AMP_API_KEY = stored;
    }
  }
  if (process.env.AMP_ACP_TRANSPORT === "sdk") {
    preferBundledAmpCliBinary();
  }
  runAcp();
  process.stdin.resume();
}
