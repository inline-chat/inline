import { invokeMessageAction, useRealtimeClient } from "@inline/client"
import type { ChatID, MessageID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { inputPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { inlineLog } from "~/inline/logging/InlineLogging"
import { writeInlineClipboardText } from "~/ui/InlineClipboard"
import { useInlineToast } from "~/ui/InlineToast"
import { colors } from "../styles/tokens.stylex"
import { useRef, useState } from "react"
import type {
  ChatMessageAction,
  ChatMessageActionRows,
} from "./ChatRowListModel"

const log = inlineLog.withScope("UI.MessageAction")

export function MessageActionRowsView({
  actions,
  chatId,
  messageId,
  peer,
}: {
  actions: ChatMessageActionRows
  chatId: ChatID
  messageId: MessageID
  peer: InlinePeerRoute
}) {
  const realtime = useRealtimeClient()
  const toast = useInlineToast()
  const runningActions = useRef(new Set<string>())
  const [pendingActions, setPendingActions] = useState<ReadonlySet<string>>(
    () => new Set(),
  )
  const run = (action: ChatMessageAction) => {
    const actionKey = `${action.kind}:${action.id}`
    if (runningActions.current.has(actionKey)) return
    runningActions.current.add(actionKey)
    setPendingActions((current) => new Set(current).add(actionKey))
    const operation =
      action.kind === "copyText"
        ? writeInlineClipboardText(action.text).then(() => {
            toast.show("Copied")
          })
        : realtime
            .mutate(
              invokeMessageAction({
                chatId,
                messageId,
                peerId: inputPeer(peer),
                actionId: action.id,
              }),
            )
            .then(async (result) => {
              if (
                !result ||
                result.oneofKind !== "invokeMessageAction" ||
                result.invokeMessageAction.interactionId <= 0n
              ) {
                throw new Error("Invalid message action response")
              }
              const answer =
                await realtime.waitForMessageActionAnswer?.(
                  result.invokeMessageAction.interactionId,
                )
              if (answer?.ui?.kind.oneofKind === "toast") {
                const text = answer.ui.kind.toast.text.trim()
                if (text) toast.show(text)
              }
            })
    void operation
      .catch((cause: unknown) => {
        log.warn("ui.message.bot_action.failed", { error: cause })
        toast.show("Could not run action", "error")
      })
      .finally(() => {
        runningActions.current.delete(actionKey)
        setPendingActions((current) => {
          const next = new Set(current)
          next.delete(actionKey)
          return next
        })
      })
  }

  return (
    <span aria-label="Message actions" {...stylex.props(styles.root)}>
      {actions.rows.map((row, rowIndex) => (
        <span key={rowIndex} {...stylex.props(styles.row)}>
          {row.map((action) => (
            <button
              key={action.id}
              type="button"
              aria-busy={
                pendingActions.has(`${action.kind}:${action.id}`) || undefined
              }
              disabled={pendingActions.has(`${action.kind}:${action.id}`)}
              onClick={() => run(action)}
              {...stylex.props(styles.action)}
            >
              {action.label}
            </button>
          ))}
        </span>
      ))}
    </span>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 4,
    marginTop: 3,
  },
  row: {
    minWidth: 0,
    display: "flex",
    gap: 4,
  },
  action: {
    minWidth: 0,
    minHeight: 28,
    flex: 1,
    paddingBlock: 5,
    paddingInline: 9,
    overflow: "hidden",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: "color-mix(in srgb, currentColor 25%, transparent)",
    borderRadius: 7,
    backgroundColor: {
      default: "color-mix(in srgb, currentColor 8%, transparent)",
      ":hover": "color-mix(in srgb, currentColor 14%, transparent)",
    },
    color: "inherit",
    fontFamily: "inherit",
    fontSize: 11,
    fontWeight: 550,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    cursor: "pointer",
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: colors.accent,
      outlineOffset: 1,
    },
  },
})
