import { AgentSessionState, type AgentSession } from "@inline-chat/protocol/core"
import type { DbAgentSession } from "@in/server/db/schema"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"
import { Log } from "@in/server/utils/log"

const log = new Log("AgentSessions.state")

export function encryptAgentSessionState(state: AgentSessionState): Buffer {
  return Encryption2.encrypt(AgentSessionState.toBinary(state))
}

export function decryptAgentSessionState(payload: Buffer | null): AgentSessionState | undefined {
  if (payload === null) return undefined
  try {
    return AgentSessionState.fromBinary(Encryption2.decryptBinary(payload))
  } catch (error) {
    log.warn("Skipping unreadable agent session state", { error })
    return undefined
  }
}

export function encryptWorkspaceLabel(label: string): Buffer {
  return Encryption2.encrypt(Buffer.from(label, "utf8"))
}

/** Bridge v2 fields of the client AgentSession for one stored row. */
export function agentSessionV2Fields(
  row: Pick<DbAgentSession, "parentSessionId" | "relation" | "stateEncrypted" | "workspaceLabelEncrypted">,
): Pick<AgentSession, "parentSessionId" | "relation" | "state" | "workspaceLabel"> {
  let workspaceLabel: string | undefined
  if (row.workspaceLabelEncrypted !== null) {
    try {
      workspaceLabel = Encryption2.decryptToString(row.workspaceLabelEncrypted)
    } catch (error) {
      log.warn("Skipping unreadable agent workspace label", { error })
    }
  }
  return {
    parentSessionId: row.parentSessionId ?? undefined,
    relation: row.relation,
    state: decryptAgentSessionState(row.stateEncrypted),
    workspaceLabel,
  }
}
