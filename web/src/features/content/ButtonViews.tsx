/**
 * Bot buttons (Mac `MessageActionRowsView`): rows of equal-width buttons, and
 * the same button for agent cards. A plain `openUrl` web link is an anchor
 * from the link allowlist; everything else calls `onAction`. A button the
 * viewer cannot use is disabled, with its reason shown under it.
 */

import * as stylex from "@stylexjs/stylex"
import type { ButtonModel, ButtonRowsModel } from "@inline/chat-ui"
import { useSignal } from "@inline/reactive/react"
import { Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { memo, useId } from "react"
import { presentButton } from "./buttons"
import { ExternalIcon } from "./icons"
import type { RowContent } from "./row-content"

export function ActionButton(props: { button: ButtonModel; ctx: RowContent; grow?: boolean }) {
  const { button, ctx } = props
  const presentation = presentButton(button, ctx.env.canUse)
  const pending = useSignal(ctx.runner.isPending(button.actionId))
  const reasonId = useId()
  const look = [styles.button, toneStyles[button.style], props.grow && styles.grow]
  if (presentation.kind === "link") {
    const link = presentation.link
    const onExternalLink = ctx.env.handlers.onExternalLink
    return (
      <a
        href={link.href}
        target="_blank"
        rel="noopener noreferrer"
        title={link.href}
        onClick={onExternalLink ? (event) => onExternalLink(link, event) : undefined}
        {...stylex.props(...look)}
      >
        <span {...stylex.props(styles.label)}>{button.label}</span>
        <ExternalIcon />
      </a>
    )
  }
  if (presentation.kind === "disabled") {
    return (
      <span {...stylex.props(styles.disabledCell, props.grow && styles.grow)}>
        <button type="button" disabled aria-describedby={reasonId} {...stylex.props(...look, styles.disabled)}>
          <span {...stylex.props(styles.label)}>{button.label}</span>
        </button>
        <span id={reasonId} {...stylex.props(styles.reason)}>
          {presentation.reason}
        </span>
      </span>
    )
  }
  const onAction = ctx.env.handlers.onAction
  return (
    <button
      type="button"
      aria-busy={pending || undefined}
      disabled={!onAction}
      onClick={onAction ? () => ctx.runner.run(button, () => onAction({ rowId: ctx.rowId, button })) : undefined}
      {...stylex.props(...look, !onAction && styles.disabled)}
    >
      {pending && <Progress variant="spinner" label="Waiting for the bot" />}
      <span {...stylex.props(styles.label)}>{button.label}</span>
    </button>
  )
}

/** The message's button rows, under the bubble. */
export const ButtonRows = memo(function ButtonRows(props: { model: ButtonRowsModel; ctx: RowContent }) {
  if (props.model.rows.length === 0) return null
  return (
    <div role="group" aria-label="Message actions" {...stylex.props(styles.rows)}>
      {props.model.rows.map((row) => (
        <div key={row.map((button) => button.key).join("|")} {...stylex.props(styles.row)}>
          {row.map((button) => (
            <ActionButton key={button.key} button={button} ctx={props.ctx} grow />
          ))}
        </div>
      ))}
    </div>
  )
})

/** A row of card buttons that keep their natural width. */
export function CardButtons(props: { buttons: readonly ButtonModel[]; ctx: RowContent }) {
  if (props.buttons.length === 0) return null
  return (
    <div {...stylex.props(styles.cardButtons)}>
      {props.buttons.map((button) => (
        <ActionButton key={button.key} button={button} ctx={props.ctx} />
      ))}
    </div>
  )
}

const styles = stylex.create({
  rows: { display: "flex", flexDirection: "column", gap: "4px", minInlineSize: 0 },
  row: { display: "flex", gap: "4px", minInlineSize: 0 },
  cardButtons: { display: "flex", flexWrap: "wrap", gap: space.sm },
  grow: { flexGrow: 1, flexBasis: 0, minInlineSize: 0 },
  button: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    gap: space.xs,
    minBlockSize: "28px",
    paddingInline: space.lg,
    boxSizing: "border-box",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    fontFamily: "inherit",
    fontSize: font.sizeBody,
    fontWeight: font.weightMedium,
    lineHeight: "16px",
    textDecoration: "none",
    cursor: { default: "pointer", ":disabled": "default" },
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    outlineOffset: "1px",
    userSelect: "none",
  },
  label: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minInlineSize: 0 },
  disabled: { opacity: 0.5 },
  disabledCell: { display: "inline-flex", flexDirection: "column", alignItems: "stretch", gap: "2px", minInlineSize: 0 },
  reason: { fontSize: font.sizeFootnote, lineHeight: "13px", color: color.secondaryLabel, textAlign: "center" },
})

const toneStyles = stylex.create({
  default: {
    backgroundColor: { default: color.control, ":hover": color.controlHover },
    color: color.controlText,
  },
  primary: {
    backgroundColor: { default: color.accent, ":hover": color.accentHover },
    borderColor: "transparent",
    color: color.onAccent,
  },
  destructive: {
    backgroundColor: { default: color.control, ":hover": color.controlHover },
    color: color.destructive,
  },
})
