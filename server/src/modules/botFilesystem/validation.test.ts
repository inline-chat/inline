import { expect, test } from "bun:test"
import { validateFilesystemRequest, validateFilesystemResponse } from "./validation"
import { RequestBotFilesystemInput_Operation as Operation, BotFilesystemEntry_Kind as Kind } from "@inline-chat/protocol/core"
const request = { botUserId: 1n, hostInstallationId: "host-1", operation: Operation.LIST, path: "", after: "" }

test("home listing and folder registration have distinct contracts", () => {
  expect(() => validateFilesystemRequest(request)).not.toThrow()
  expect(() => validateFilesystemRequest({ ...request, operation: Operation.REGISTER_FOLDER })).toThrow()
  expect(() => validateFilesystemRequest({ ...request, operation: Operation.REGISTER_FOLDER, path: "/home/project" })).not.toThrow()
  expect(() => validateFilesystemRequest({ ...request, after: "../secret" })).toThrow()
  expect(() => validateFilesystemRequest({ ...request, path: "a".repeat(4097) })).toThrow()
})
test("listing names cannot escape their directory and pages are bounded", () => {
  const listing = { path: "/home", entries: [{ name: "project", kind: Kind.DIRECTORY, size: 0n }] }
  expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing } })).not.toThrow()
  for (const name of ["..", "/etc", "a/b", "a\\b", "bad\nname"]) {
    expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing: { ...listing, entries: [{ ...listing.entries[0]!, name }] } } })).toThrow()
  }
  expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing: { ...listing, entries: Array(201).fill(listing.entries[0]) } } })).toThrow()
})

test("remote browsing capability survives settings normalization", async () => {
  const { normalizeBotChatSettingsResponse } = await import("../botChatSettings/validation")
  const response = normalizeBotChatSettingsResponse({ result: { oneofKind: "document", document: {
    version: 1, revision: "one", sections: [{ id: "project", items: [{ id: "folder", label: "Folder", disabled: false, control: {
      oneofKind: "folder", folder: {
        value: "workspace-1", recentFolders: [{ value: "workspace-1", label: "Project", disabled: false }],
        hostInstallationId: "host-1", hostLabel: "Remote Mac", allowsLocalPicker: false, remoteBrowserVersion: 1,
      },
    } }] }],
  } } })
  expect(response.result.oneofKind).toBe("document")
  if (response.result.oneofKind !== "document") return
  const control = response.result.document.sections[0]!.items[0]!.control
  expect(control.oneofKind === "folder" && control.folder.remoteBrowserVersion).toBe(1)
})

test("pagination cursor identifies the last returned entry", () => {
  const listing = { path: "/home", entries: [{ name: "project", kind: Kind.DIRECTORY, size: 0n }], nextAfter: "project" }
  expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing } })).not.toThrow()
  expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing: { ...listing, nextAfter: "other" } } })).toThrow()
  expect(() => validateFilesystemResponse({ result: { oneofKind: "listing", listing: { ...listing, entries: [] } } })).toThrow()
})
