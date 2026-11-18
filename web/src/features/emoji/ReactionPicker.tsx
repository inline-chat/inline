/**
 * The reaction picker's views. `ReactionPickerView` is the content (the
 * quick row, or the full picker once expanded); put it in the popover that
 * anchors it. `ReactionPickerPopover` does that with the controller's own
 * popover. Behavior is in `ReactionPickerController`.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { ContextMenuArea, PopoverContent } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { EmojiPicker, EmojiPickerPlaceholder } from "./EmojiPicker"
import { emojiTokens } from "./emoji.stylex"
import type { ReactionPickerController } from "./reaction-picker"

/** In a popover the caller owns (`MessageActions.picker`): `<PopoverContent controller={popover} style={reactionPickerPopoverStyle}>`. */
export function ReactionPickerView(props: { controller: ReactionPickerController }) {
  const mode = useSignal(props.controller.mode)
  return mode === "full" ? <FullPicker controller={props.controller} /> : <QuickRow controller={props.controller} />
}

/** With the controller's own popover. */
export function ReactionPickerPopover(props: { controller: ReactionPickerController }) {
  return (
    <PopoverContent controller={props.controller.popover} style={reactionPickerPopoverStyle}>
      <ReactionPickerView controller={props.controller} />
    </PopoverContent>
  )
}

function FullPicker(props: { controller: ReactionPickerController }) {
  const picker = useSignal(props.controller.full)
  return picker ? <EmojiPicker controller={picker} /> : <EmojiPickerPlaceholder />
}

function QuickRow(props: { controller: ReactionPickerController }) {
  const { controller } = props
  const rowRef = useElement(controller.row)
  const items = useSignal(controller.quick)
  const focus = useSignal(controller.focusIndex)
  return (
    <ContextMenuArea controller={controller.suggestionMenu} style={styles.area}>
      <div ref={rowRef} {...stylex.props(styles.row)}>
        <div {...stylex.props(styles.strip)}>
          {/* Keyed by place, not emoji: a new row for a new message updates the
              buttons in place, so the focused one is never moved in the DOM
              (which blurs it) and stays at the controller's focus index. */}
          {items.map((item, index) => (
            <button
              key={index}
              type="button"
              data-quick-index={index}
              tabIndex={focus === index ? 0 : -1}
              aria-pressed={item.mine}
              aria-label={item.mine ? `Remove ${item.emoji}` : `React with ${item.emoji}`}
              title={item.removable ? "Right-click to remove from suggestions" : undefined}
              onClick={() => controller.choose(item.emoji)}
              {...stylex.props(styles.quick, styles.focusRing, item.mine && styles.quickMine)}
            >
              <span aria-hidden="true" {...stylex.props(styles.emojiText)}>
                {item.emoji}
              </span>
            </button>
          ))}
        </div>
        <button
          type="button"
          data-quick-index={items.length}
          tabIndex={focus === items.length ? 0 : -1}
          aria-label="More reactions"
          aria-haspopup="dialog"
          onClick={() => controller.expand()}
          {...stylex.props(styles.more, styles.focusRing)}
        >
          <svg aria-hidden="true" viewBox="0 0 16 16" width="14" height="14" {...stylex.props(styles.plus)}>
            <path d="M8 3v10M3 8h10" strokeWidth="1.8" strokeLinecap="round" fill="none" />
          </svg>
        </button>
      </div>
    </ContextMenuArea>
  )
}

const styles = stylex.create({
  area: {
    display: "block",
  },
  row: {
    display: "flex",
    alignItems: "center",
    gap: space.xxs,
    paddingInline: space.xxs,
    maxInlineSize: `min(${emojiTokens.quickRowWidth}, var(--ui-available-width, 100vw))`,
    boxSizing: "border-box",
  },
  strip: {
    display: "flex",
    gap: space.xxs,
    overflowX: "auto",
    scrollbarWidth: "none",
    minInlineSize: 0,
    paddingInlineStart: space.xs,
    // The strip scrolls sideways, which clips it top and bottom too: room
    // for a button scaled on hover (32 px at 1.1).
    paddingBlock: space.xxs,
  },
  emojiText: {
    fontFamily: emojiTokens.fontFamily,
    fontVariantEmoji: "emoji",
    fontSize: emojiTokens.quickFont,
    lineHeight: 1,
  },
  focusRing: {
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: `calc(-1 * ${size.focusRingWidth})`,
  },
  quick: {
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    inlineSize: emojiTokens.quickButton,
    blockSize: emojiTokens.quickButton,
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    cursor: "pointer",
    transform: { default: "scale(1)", ":hover": "scale(1.1)" },
    transitionProperty: "transform, background-color",
    transitionDuration: motion.durationFast,
    transitionTimingFunction: motion.easeOut,
  },
  quickMine: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
    "@media (forced-colors: active)": { outline: "2px solid Highlight" },
  },
  more: {
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    inlineSize: emojiTokens.quickButton,
    blockSize: emojiTokens.quickButton,
    padding: 0,
    marginInlineEnd: space.xs,
    borderStyle: "none",
    borderRadius: radius.pill,
    backgroundColor: { default: color.controlHover, ":hover": color.controlPressed },
    color: color.label,
    cursor: "pointer",
    fontFamily: font.familySystem,
  },
  plus: {
    stroke: "currentColor",
  },
})

/** The popover surface: no padding (the row and the picker carry their own). */
export const reactionPickerPopoverStyle = stylex.create({
  surface: { padding: 0, minInlineSize: 0 },
}).surface
