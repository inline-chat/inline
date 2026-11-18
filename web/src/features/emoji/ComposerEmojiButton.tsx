/**
 * The composer's emoji button and its popover with the full picker. The
 * picker appears once the emoji data has loaded (a placeholder of the same
 * size before). Behavior is in `ComposerEmojiPicker`.
 */

import { useSignal } from "@inline/reactive/react"
import { IconButton, PopoverContent } from "@inline/ui/react"
import * as stylex from "@stylexjs/stylex"
import type { ComposerEmojiPicker } from "./composer-picker"
import { EmojiPicker, EmojiPickerPlaceholder } from "./EmojiPicker"
import { reactionPickerPopoverStyle } from "./ReactionPicker"

export function ComposerEmojiButton(props: { controller: ComposerEmojiPicker; style?: stylex.StyleXStyles }) {
  return (
    <>
      <IconButton
        label="Emoji"
        part={props.controller.trigger}
        icon={<SmileIcon />}
        {...(props.style ? { style: props.style } : {})}
      />
      <ComposerEmojiPopover controller={props.controller} />
    </>
  )
}

/** The popover alone, for a caller that draws its own button and attaches `controller.trigger` to it. */
export function ComposerEmojiPopover(props: { controller: ComposerEmojiPicker }) {
  const open = useSignal(props.controller.popover.isOpen)
  const picker = useSignal(props.controller.picker)
  return (
    <PopoverContent controller={props.controller.popover} style={reactionPickerPopoverStyle}>
      {open ? picker ? <EmojiPicker controller={picker} /> : <EmojiPickerPlaceholder /> : null}
    </PopoverContent>
  )
}

const SmileIcon = () => (
  <svg aria-hidden="true" viewBox="0 0 16 16" width="16" height="16" {...stylex.props(styles.icon)}>
    <circle cx="8" cy="8" r="6.25" fill="none" strokeWidth="1.3" />
    <path d="M5.4 9.6c.6.9 1.5 1.4 2.6 1.4s2-.5 2.6-1.4" fill="none" strokeWidth="1.3" strokeLinecap="round" />
    <circle cx="6" cy="6.6" r=".9" />
    <circle cx="10" cy="6.6" r=".9" />
  </svg>
)

const styles = stylex.create({
  icon: {
    stroke: "currentColor",
    fill: "currentColor",
  },
})
