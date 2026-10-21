import { describe, expect, test } from "bun:test"
import { readdirSync, readFileSync, statSync } from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

// `ChatModel.getChatFromInputPeerUnchecked` returns any chat by ID. Two callers
// once treated it as an access check (translation and compose actions). New
// code should use `ChatModel.getAuthorizedChatFromInputPeer`; adding a file
// here means its author reviewed that every path authorizes the chat itself.
const reviewedUncheckedCallers = new Set([
  "controllers/bot/bot.ts",
  "controllers/bot/operations.ts",
  "db/models/chats.ts",
  "functions/bot.getPresence.ts",
  "functions/bot.peerDiscovery.ts",
  "functions/bot.setPresenceState.ts",
  "functions/messages.acknowledgeMessages.ts",
  "functions/messages.addReaction.ts",
  "functions/messages.collapseHistory.ts",
  "functions/messages.deleteChat.ts",
  "functions/messages.deleteMessage.ts",
  "functions/messages.deleteMessageAttachment.ts",
  "functions/messages.deleteReaction.ts",
  "functions/messages.dialogFolders.ts",
  "functions/messages.editMessage.ts",
  "functions/messages.forwardMessages.ts",
  "functions/messages.getChatTranscript.ts",
  "functions/messages.invokeMessageAction.ts",
  "functions/messages.markAsUnread.ts",
  "functions/messages.pinMessage.ts",
  "functions/messages.readMessages.ts",
  "functions/messages.sendMessage.ts",
  "functions/messages.showInChatList.ts",
  "functions/messages.updateDialogFollowMode.ts",
  "functions/messages.updateDialogNotificationSettings.ts",
  "functions/messages.updateDialogOpen.ts",
  "functions/messages.updateDialogOrder.ts",
  "functions/messages.updateDialogTranslation.ts",
  "functions/space.urlPreviewExclusions.ts",
  "functions/updates.getUpdates.ts",
  "modules/agentSessions/service.ts",
  "modules/externalResources/externalResources.effect.ts",
  "modules/historyClear/index.ts",
  "modules/message/historySnapshot.ts",
  // Recipient projection only; callers authorize before emitting.
  "modules/updates/index.ts",
  "realtime/handlers/urlPreview.resolve.ts",
])

const productionSources = (root: string, dir = root): string[] =>
  readdirSync(dir).flatMap((entry) => {
    const full = path.join(dir, entry)
    if (statSync(full).isDirectory()) {
      return entry === "__tests__" || entry === "node_modules" ? [] : productionSources(root, full)
    }
    return entry.endsWith(".ts") && !entry.endsWith(".test.ts") ? [path.relative(root, full)] : []
  })

describe("chat lookup authorization guardrail", () => {
  test("only reviewed files resolve caller-named chats without the access check", () => {
    const srcRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..")
    const callers = productionSources(srcRoot)
      .filter((file) => readFileSync(path.join(srcRoot, file), "utf8").includes("getChatFromInputPeerUnchecked"))
      .map((file) => file.split(path.sep).join("/"))
      .sort()

    expect(callers).toEqual([...reviewedUncheckedCallers].sort())
  })
})
