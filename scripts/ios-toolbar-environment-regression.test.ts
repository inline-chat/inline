import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..");

function source(path: string): string {
  return readFileSync(join(repoRoot, path), "utf8");
}

function swiftSources(directory: string): Array<{ contents: string; path: string }> {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return swiftSources(path);
    if (!entry.isFile() || !entry.name.endsWith(".swift")) return [];
    return [{ contents: readFileSync(path, "utf8"), path }];
  });
}

function typeBody(contents: string, typeName: string): string {
  const declaration = new RegExp(`\\bstruct\\s+${typeName}\\s*:`).exec(contents);
  if (!declaration) throw new Error(`Type declaration not found: ${typeName}`);

  const openingBrace = contents.indexOf("{", declaration.index);
  let depth = 0;
  let inLineComment = false;
  let inBlockComment = false;
  let inString = false;
  let escapedCharacter = false;

  for (let index = openingBrace; index < contents.length; index += 1) {
    const character = contents[index];
    const next = contents[index + 1];

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
      if (escapedCharacter) escapedCharacter = false;
      else if (character === "\\") escapedCharacter = true;
      else if (character === '"') inString = false;
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
    if (character === '"') {
      inString = true;
      continue;
    }
    if (character === "{") depth += 1;
    if (character === "}") {
      depth -= 1;
      if (depth === 0) return contents.slice(openingBrace + 1, index);
    }
  }

  throw new Error(`Unterminated type declaration: ${typeName}`);
}

function matchCount(contents: string, pattern: RegExp): number {
  return contents.match(pattern)?.length ?? 0;
}

function rehostSafeTypes(): Array<{ body: string; name: string; path: string }> {
  return swiftSources(join(repoRoot, "apple/InlineIOS")).flatMap(({ contents, path }) => {
    const declarations = contents.matchAll(/\bstruct\s+(\w+)\s*:\s*([^\{]+)\{/g);
    return [...declarations]
      .filter((declaration) => declaration[2].includes("RehostSafeToolbarContent"))
      .map((declaration) => ({
        body: typeBody(contents, declaration[1]),
        name: declaration[1],
        path,
      }));
  });
}

describe("iOS toolbar environment crash boundary", () => {
  const chat = source("apple/InlineIOS/Features/Chat/ChatView.swift");
  const chatLeading = source("apple/InlineIOS/Features/Chat/ChatView+extensions.swift");
  const home = source("apple/InlineIOS/MainViews/HomeToolbarContent.swift");
  const homeView = source("apple/InlineIOS/MainViews/HomeView.swift");
  const notificationSettings = source("apple/InlineIOS/UI/NotificationSettingsPopover.swift");
  const experimentalRoot = source("apple/InlineIOS/ExperimentalRootView.swift");
  const spacePicker = source("apple/InlineIOS/UI/SpacePickerMenu.swift");

  test("marked toolbar-hosted views never require app-owned environment dependencies", () => {
    const safeTypes = rehostSafeTypes();
    expect(safeTypes.map(({ name }) => name)).toEqual(expect.arrayContaining([
      "ChatToolbarLeadingView",
      "HomeToolbarContent",
      "NotificationSettingsButton",
      "NotificationSettingsPopoverContent",
      "NotificationSettingsList",
      "SpacePickerMenu",
    ]));

    for (const { body, name, path } of safeTypes) {
      expect(body, `${name} in ${path}`).not.toMatch(/@EnvironmentObject\b/);
      expect(body, `${name} in ${path}`).not.toMatch(/@EnvironmentStateObject\b/);
      expect(body, `${name} in ${path}`).not.toMatch(
        /@Environment\(\s*(?!\\\.)[^)]+\.self\s*\)/,
      );
    }
  });

  test("stable parents pass rehosted dependencies explicitly", () => {
    expect(typeBody(chatLeading, "ChatToolbarLeadingView")).toMatch(/private let router:\s*Router/);
    expect(typeBody(chatLeading, "ChatToolbarLeadingView")).toMatch(
      /@ObservedObject private var fullChatViewModel:\s*FullChatViewModel/,
    );
    expect(typeBody(home, "HomeToolbarContent")).toMatch(/private let router:\s*Router/);
    expect(typeBody(home, "HomeToolbarContent")).toMatch(
      /@ObservedObject private var realtimeState:\s*RealtimeState/,
    );
    expect(typeBody(home, "HomeToolbarContent")).toMatch(
      /@ObservedObject private var notificationSettings:\s*NotificationSettingsManager/,
    );
    expect(typeBody(notificationSettings, "NotificationSettingsButton")).toMatch(
      /@ObservedObject private var notificationSettings:\s*NotificationSettingsManager/,
    );
    expect(typeBody(spacePicker, "SpacePickerMenu")).toMatch(
      /@ObservedObject private var compactSpaceList:\s*CompactSpaceList/,
    );
    expect(typeBody(spacePicker, "SpacePickerMenu")).toMatch(
      /@ObservedObject private var realtimeState:\s*RealtimeState/,
    );

    const chatView = typeBody(chat, "ChatView");
    expect(matchCount(chatView, /ChatToolbarLeadingView\([\s\S]{0,400}?router:\s*router[\s\S]{0,100}?fullChatViewModel:\s*fullChatViewModel/g))
      .toBe(2);
    expect(typeBody(homeView, "HomeView")).toMatch(
      /HomeToolbarContent\([\s\S]{0,300}?router:\s*router,[\s\S]{0,100}?realtimeState:\s*realtimeState,[\s\S]{0,100}?notificationSettings:\s*notificationSettings/,
    );
    expect(typeBody(experimentalRoot, "ExperimentalAuthedRootView")).toMatch(
      /SpacePickerMenu\([\s\S]{0,300}?compactSpaceList:\s*compactSpaceList,[\s\S]{0,100}?realtimeState:\s*realtimeState/,
    );

    if (!chat.includes("struct ChatToolbarMoreMenuHost")) return;

    for (const typeName of [
      "ChatToolbarMoreMenuHost",
      "ChatToolbarObservedVisibilityMenu",
      "ChatToolbarMoreMenu",
    ]) {
      expect(typeBody(chat, typeName)).toMatch(/(?:private )?let router:\s*Router/);
    }
    expect(chatView).toMatch(
      /ChatToolbarMoreMenuHost\([\s\S]{0,500}?router:\s*router/,
    );
    expect(chatView).toMatch(
      /ChatToolbarMoreMenuHost\([\s\S]{0,700}?realtimeV2:\s*realtimeV2,[\s\S]{0,100}?notificationSettings:\s*notificationSettings/,
    );

    const moreMenuHost = typeBody(chat, "ChatToolbarMoreMenuHost");
    expect(moreMenuHost).toMatch(
      /ChatToolbarObservedVisibilityMenu\([\s\S]{0,500}?router:\s*router/,
    );
    expect(moreMenuHost).toMatch(
      /else\s*\{[\s\S]{0,100}?ChatToolbarMoreMenu\([\s\S]{0,500}?router:\s*router/,
    );
    expect(typeBody(chat, "ChatToolbarObservedVisibilityMenu")).toMatch(
      /ChatToolbarMoreMenu\([\s\S]{0,500}?router:\s*router/,
    );
  });
});
