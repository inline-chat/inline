import { readFileSync } from "node:fs";

export type ToolbarDependencyStrategy =
  | "required-environment"
  | "optional-environment"
  | "explicit-dependency"
  | "unclassified";

export type ToolbarDependencyAudit = {
  viewName: string;
  dependencyType: string;
  dependencyName: string;
  strategy: ToolbarDependencyStrategy;
  requiredEnvironmentLines: number[];
  optionalEnvironmentLines: number[];
  hasExplicitStoredDependency: boolean;
  hasExplicitInitializerParameter: boolean;
  hostPassesExplicitDependency: boolean;
  toolbarPlacements: string[];
};

function lineNumber(source: string, offset: number): number {
  return source.slice(0, offset).split("\n").length;
}

function escaped(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function extractTypeBody(source: string, viewName: string): { body: string; offset: number } {
  const declaration = new RegExp(`\\bstruct\\s+${escaped(viewName)}\\s*:\\s*View\\s*\\{`).exec(source);
  if (!declaration) throw new Error(`View declaration not found: ${viewName}`);

  const openingBrace = source.indexOf("{", declaration.index);
  let depth = 0;
  let inLineComment = false;
  let inBlockComment = false;
  let inString = false;
  let escapedCharacter = false;

  for (let index = openingBrace; index < source.length; index += 1) {
    const character = source[index];
    const next = source[index + 1];

    if (inLineComment) {
      if (character === "\n") inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (character === "*" && next === "/") {
        inBlockComment = false;
        index += 1;
      }
      continue;
    }
    if (inString) {
      if (escapedCharacter) {
        escapedCharacter = false;
      } else if (character === "\\") {
        escapedCharacter = true;
      } else if (character === "\"") {
        inString = false;
      }
      continue;
    }
    if (character === "/" && next === "/") {
      inLineComment = true;
      index += 1;
      continue;
    }
    if (character === "/" && next === "*") {
      inBlockComment = true;
      index += 1;
      continue;
    }
    if (character === "\"") {
      inString = true;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) {
        return { body: source.slice(openingBrace + 1, index), offset: openingBrace + 1 };
      }
    }
  }

  throw new Error(`Unterminated view declaration: ${viewName}`);
}

function environmentLines(
  source: string,
  originalSource: string,
  sourceOffset: number,
  dependencyType: string,
  dependencyName: string,
): { required: number[]; optional: number[] } {
  const annotation = new RegExp(
    `@Environment\\(\\s*${escaped(dependencyType)}\\.self\\s*\\)[^\\n]*\\bvar\\s+${escaped(dependencyName)}(?:\\s*:\\s*${escaped(dependencyType)}\\s*(\\?))?`,
    "g",
  );
  const required: number[] = [];
  const optional: number[] = [];
  for (const match of source.matchAll(annotation)) {
    const line = lineNumber(originalSource, sourceOffset + (match.index ?? 0));
    if (match[1] === "?") optional.push(line);
    else required.push(line);
  }
  return { required, optional };
}

function toolbarPlacements(hostSource: string, viewName: string): string[] {
  const placements = new Set<string>();
  const call = new RegExp(`\\b${escaped(viewName)}\\s*\\(`, "g");
  for (const match of hostSource.matchAll(call)) {
    const prefix = hostSource.slice(Math.max(0, (match.index ?? 0) - 500), match.index);
    const toolbarMatches = [...prefix.matchAll(/ToolbarItem\s*\(\s*placement:\s*\.([A-Za-z0-9_]+)/g)];
    const nearest = toolbarMatches.at(-1);
    if (nearest) placements.add(nearest[1]);
  }
  return [...placements].sort();
}

export function auditToolbarDependency(input: {
  toolbarSource: string;
  hostSource: string;
  viewName: string;
  dependencyType: string;
  dependencyName: string;
}): ToolbarDependencyAudit {
  const view = extractTypeBody(input.toolbarSource, input.viewName);
  const lines = environmentLines(
    view.body,
    input.toolbarSource,
    view.offset,
    input.dependencyType,
    input.dependencyName,
  );
  const storedDependencyPattern = new RegExp(
    `\\b(?:let|var)\\s+${escaped(input.dependencyName)}\\s*:\\s*${escaped(input.dependencyType)}\\b`,
    "g",
  );
  const storedDependency = [...view.body.matchAll(storedDependencyPattern)].some((match) => {
    const offset = match.index ?? 0;
    const lineStart = view.body.lastIndexOf("\n", offset) + 1;
    const lineEnd = view.body.indexOf("\n", offset);
    const declarationLine = view.body.slice(lineStart, lineEnd < 0 ? view.body.length : lineEnd);
    return !declarationLine.includes("@Environment");
  });
  const initializerParameter = new RegExp(
    `\\b${escaped(input.dependencyName)}\\s*:\\s*${escaped(input.dependencyType)}\\b`,
  ).test(view.body.match(/\binit\s*\([\s\S]*?\)\s*\{/m)?.[0] ?? "");
  const hostCall = new RegExp(
    `\\b${escaped(input.viewName)}\\s*\\([\\s\\S]{0,1200}?\\b${escaped(input.dependencyName)}\\s*:`,
  ).test(input.hostSource);

  let strategy: ToolbarDependencyStrategy = "unclassified";
  if (lines.required.length > 0) strategy = "required-environment";
  else if (lines.optional.length > 0) strategy = "optional-environment";
  else if (storedDependency && initializerParameter && hostCall) strategy = "explicit-dependency";

  return {
    viewName: input.viewName,
    dependencyType: input.dependencyType,
    dependencyName: input.dependencyName,
    strategy,
    requiredEnvironmentLines: lines.required,
    optionalEnvironmentLines: lines.optional,
    hasExplicitStoredDependency: storedDependency,
    hasExplicitInitializerParameter: initializerParameter,
    hostPassesExplicitDependency: hostCall,
    toolbarPlacements: toolbarPlacements(input.hostSource, input.viewName),
  };
}

function argument(name: string): string {
  const index = Bun.argv.indexOf(name);
  const value = index >= 0 ? Bun.argv[index + 1] : undefined;
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

if (import.meta.main) {
  const toolbarPath = argument("--toolbar-view");
  const hostPath = argument("--host");
  const result = auditToolbarDependency({
    toolbarSource: readFileSync(toolbarPath, "utf8"),
    hostSource: readFileSync(hostPath, "utf8"),
    viewName: argument("--view"),
    dependencyType: argument("--dependency-type"),
    dependencyName: argument("--dependency-name"),
  });
  console.log(JSON.stringify(result, null, 2));
  if (Bun.argv.includes("--require-safe") && result.strategy === "required-environment") process.exit(1);
}
