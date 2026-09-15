import type {
  ChannelApprovalKind,
  ChannelApprovalNativeAvailabilityAdapter,
} from "openclaw/plugin-sdk/approval-handler-runtime"

// Infer the host's request union so August hosts do not need September-only
// named type exports. Older hosts ignore event kinds they do not dispatch.
export type InlineApprovalRequest = Parameters<ChannelApprovalNativeAvailabilityAdapter["shouldHandle"]>[0]["request"]
export const INLINE_APPROVAL_EVENT_KINDS = ["exec", "plugin", "system-agent"] as readonly ChannelApprovalKind[]
