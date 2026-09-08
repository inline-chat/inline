import { BotFilesystemEntry_Kind, RequestBotFilesystemInput_Operation, type BotFilesystemResponse, type RequestBotFilesystemInput } from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

const bounded = (value: string, bytes: number): boolean => new TextEncoder().encode(value).length <= bytes && !Array.from(value).some((character) => character.codePointAt(0)! < 32 || character.codePointAt(0) === 127)
const component = (value: string): boolean => value.length > 0 && value !== "." && value !== ".." && bounded(value, 1024) && !value.includes("/") && !value.includes("\\")

export function validateFilesystemRequest(input: RequestBotFilesystemInput): void {
  if (!/^[A-Za-z0-9_-]{1,128}$/u.test(input.hostInstallationId)
    || !bounded(input.path, 4096) || !bounded(input.after, 1024)
    || ![RequestBotFilesystemInput_Operation.LIST, RequestBotFilesystemInput_Operation.REGISTER_FOLDER].includes(input.operation)
    || (input.after !== "" && !component(input.after))
    || (input.operation === RequestBotFilesystemInput_Operation.REGISTER_FOLDER && (input.path === "" || input.after !== ""))) {
    throw RealtimeRpcError.BadRequest()
  }
}

export function validateFilesystemResponse(response: BotFilesystemResponse | undefined): BotFilesystemResponse {
  const result = response?.result
  if (!result) throw RealtimeRpcError.BadRequest()
  switch (result.oneofKind) {
    case "problem":
      if (!result.problem || !bounded(result.problem, 256)) throw RealtimeRpcError.BadRequest()
      break
    case "workspaceId":
      if (!/^[A-Za-z0-9_.:-]{1,128}$/u.test(result.workspaceId)) throw RealtimeRpcError.BadRequest()
      break
    case "listing": {
      const page = result.listing
      if (!page.path || !bounded(page.path, 4096) || (page.parentPath !== undefined && !bounded(page.parentPath, 4096))
        || page.entries.length > 200 || (page.nextAfter !== undefined && (!component(page.nextAfter) || page.nextAfter !== page.entries.at(-1)?.name))) throw RealtimeRpcError.BadRequest()
      const seen = new Set<string>()
      for (const entry of page.entries) {
        if (!component(entry.name) || seen.has(entry.name) || entry.size < 0n
          || ![BotFilesystemEntry_Kind.FILE, BotFilesystemEntry_Kind.DIRECTORY, BotFilesystemEntry_Kind.SYMLINK, BotFilesystemEntry_Kind.OTHER].includes(entry.kind)) throw RealtimeRpcError.BadRequest()
        seen.add(entry.name)
      }
      break
    }
    default: throw RealtimeRpcError.BadRequest()
  }
  return response!
}
