import { controlAgentSession } from "@in/server/modules/agentSessions/control"
import { getAgentSessionStates, updateAgentSessionState } from "@in/server/modules/agentSessions/state"
import {
  deleteAgentGrant,
  importAgentGrants,
  listAgentGrants,
  setAgentGrant,
} from "@in/server/modules/agents/grants"
import { getAgentParticipations, setAgentParticipation } from "@in/server/modules/agents/participation"
import { getAgentRuntime, reportAgentRuntime, updateAgentSettings } from "@in/server/modules/agents/runtime"

/**
 * Bridge v2 agent RPCs. Each service authorizes the authenticated user itself
 * (owner, bot, grantee or chat member), since realtime V3 carries no is_bot flag.
 */
export const AgentHandlers = {
  reportAgentRuntime,
  getAgentRuntime,
  updateAgentSettings,
  updateAgentSessionState,
  getAgentSessionStates,
  controlAgentSession,
  listAgentGrants,
  setAgentGrant,
  deleteAgentGrant,
  importAgentGrants,
  getAgentParticipations,
  setAgentParticipation,
}
