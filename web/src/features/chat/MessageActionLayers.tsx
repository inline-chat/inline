/**
 * The layers message actions open, rendered once in the shell: the reaction
 * picker (a popover over a few common emoji, anchored at the Add Reaction
 * button or the row) and the confirmation alert (a delete, a bot button
 * with a confirm step), whose words come from what it asks. Both
 * are the kit's top-layer primitives, driven by `MessageActions`. In the
 * layers chunk (`src/app/layers-chunk.ts`); the shell renders it once the
 * chunk and the controllers are there.
 */

import { useModel, useSignal } from "@inline/reactive/react"
import { Button, Dialog, PopoverContent } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { MessageTarget } from "@inline/view/features"
import type { SessionEmoji } from "../../app/emoji-session"
import type { EmojiChunk, EmojiServices } from "../emoji"
import { deleteConfirmText, QUICK_REACTIONS, reactionTarget, type MessageActions, type MessageLayers } from "./message-actions"

export function MessageActionLayers(props: { actions: MessageActions; layers: MessageLayers; emoji?: SessionEmoji | undefined }) {
  return (
    <>
      <ReactionPicker actions={props.actions} layers={props.layers} emoji={props.emoji} />
      <Confirmation actions={props.actions} layers={props.layers} />
    </>
  )
}

const noValue = { get: () => undefined, peek: () => undefined }

/**
 * The emoji feature's reaction picker (the Mac's quick row from the message's
 * own emoji, learned picks and the default set, expanding to the full picker
 * in the same popover) once its code is there; the few common emoji before.
 */
function ReactionPicker(props: { actions: MessageActions; layers: MessageLayers; emoji?: SessionEmoji | undefined }) {
  const services = useSignal(props.emoji?.services ?? noValue)
  const pickers = useSignal(props.emoji?.pickers ?? noValue)
  if (services && pickers) return <EmojiReactionPicker actions={props.actions} layers={props.layers} services={services} pickers={pickers} />
  return <QuickReactionRow actions={props.actions} layers={props.layers} />
}

function EmojiReactionPicker(props: { actions: MessageActions; layers: MessageLayers; services: EmojiServices; pickers: EmojiChunk }) {
  const { actions, layers, services, pickers } = props
  const picker = useModel(
    () =>
      new pickers.ReactionPickerController({
        services,
        popover: layers.picker,
        target: actions.pickerTarget,
        describe: (value) => reactionTarget(value as MessageTarget),
        // Toggles; runs while the popover is still open, so `choose` still sees its target.
        onChoose: (emoji) => actions.choose(emoji),
      }),
    [actions, layers, services, pickers],
  )
  return (
    <PopoverContent controller={layers.picker} style={pickers.reactionPickerPopoverStyle}>
      <pickers.ReactionPickerView controller={picker} />
    </PopoverContent>
  )
}

function QuickReactionRow(props: { actions: MessageActions; layers: MessageLayers }) {
  const { actions } = props
  const target = useSignal(actions.pickerTarget)
  const mine = new Set(target?.row.reactions?.filter((reaction) => reaction.mine).map((reaction) => reaction.emoji) ?? [])
  return (
    <PopoverContent controller={props.layers.picker} style={styles.picker}>
      <div role="group" aria-label="Reactions" {...stylex.props(styles.row)}>
        {QUICK_REACTIONS.map((emoji) => (
          <button
            key={emoji}
            type="button"
            aria-pressed={mine.has(emoji)}
            aria-label={mine.has(emoji) ? `Remove ${emoji}` : `React with ${emoji}`}
            onClick={() => actions.choose(emoji)}
            {...stylex.props(styles.emoji, mine.has(emoji) && styles.mine)}
          >
            {emoji}
          </button>
        ))}
      </div>
    </PopoverContent>
  )
}

function Confirmation(props: { actions: MessageActions; layers: MessageLayers }) {
  const { actions } = props
  const pending = useSignal(actions.pendingConfirm)
  return (
    <Dialog
      controller={props.layers.confirm}
      title={pending?.title ?? deleteConfirmText.title}
      {...(pending?.description ? { description: pending.description } : {})}
      closeButton={false}
      children={
        pending?.detail ? (
          <p dir="auto" {...stylex.props(styles.detail)}>
            {pending.detail}
          </p>
        ) : null
      }
      footer={
        <>
          <Button variant="secondary" onClick={() => actions.cancelPending()}>
            Cancel
          </Button>
          <Button variant={pending?.destructive === false ? "primary" : "destructive"} onClick={() => actions.confirmPending()}>
            {pending?.confirmLabel ?? deleteConfirmText.confirmLabel}
          </Button>
        </>
      }
    />
  )
}

const styles = stylex.create({
  detail: {
    margin: 0,
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    overflowWrap: "anywhere",
  },
  picker: {
    minWidth: 0,
    padding: space.xs,
  },
  row: {
    display: "flex",
    gap: space.xxs,
  },
  emoji: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: 32,
    blockSize: 32,
    padding: 0,
    borderWidth: 0,
    borderRadius: radius.control,
    backgroundColor: {
      default: "transparent",
      ":hover": color.controlHover,
    },
    fontSize: 20,
    lineHeight: 1,
    cursor: "pointer",
    outlineOffset: 1,
  },
  mine: {
    backgroundColor: color.controlHover,
  },
})
