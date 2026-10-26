import { expect, test } from "bun:test"
import { validateFilesystemRequest, validateFilesystemResponse, validateFilesystemResponseFor } from "./validation"
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
  const checked = (value: typeof listing) => () =>
    validateFilesystemResponseFor(request, validateFilesystemResponse({ result: { oneofKind: "listing", listing: value } }))
  expect(checked(listing)).not.toThrow()
  for (const name of ["..", "/etc", "a/b", "a\\b", "bad\nname"]) {
    expect(checked({ ...listing, entries: [{ ...listing.entries[0]!, name }] })).toThrow()
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

test("work file listings stay relative to the work's folder", () => {
  const work = { ...request, operation: Operation.LIST_WORK_FILES, agentSessionId: 7n }
  expect(() => validateFilesystemRequest(work)).not.toThrow()
  expect(() => validateFilesystemRequest({ ...work, path: "src", query: "main", limit: 50 })).not.toThrow()
  expect(() => validateFilesystemRequest({ ...work, agentSessionId: undefined })).toThrow()
  for (const path of ["/etc", "~/x", "../up", "a/../b"]) {
    expect(() => validateFilesystemRequest({ ...work, path })).toThrow()
  }
  expect(() => validateFilesystemRequest({ ...work, limit: 201 })).toThrow()
  // Work-only fields never ride on host browsing.
  expect(() => validateFilesystemRequest({ ...request, query: "x" })).toThrow()

  const listing = { path: "src", parentPath: "", entries: [{ name: "src/main.rs", kind: Kind.FILE, size: 1n }], nextAfter: "src/main.rs" }
  const checked = (value: typeof listing) => () =>
    validateFilesystemResponseFor(work, validateFilesystemResponse({ result: { oneofKind: "listing", listing: value } }))
  expect(checked(listing)).not.toThrow()
  expect(checked({ ...listing, path: "/Users/mo/dev/inline/src" })).toThrow()
  expect(checked({ ...listing, parentPath: "/Users/mo" })).toThrow()
  expect(checked({ ...listing, entries: [{ name: "../secret", kind: Kind.FILE, size: 1n }], nextAfter: "../secret" })).toThrow()
})
