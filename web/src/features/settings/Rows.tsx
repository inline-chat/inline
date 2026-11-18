/**
 * The building blocks of a settings page, laid out like the Mac app's
 * grouped forms: a section header over a rounded group of rows, each row a
 * title (and description) on the leading side and its control on the
 * trailing side, or stacked when the control is wide. Rows take their
 * titles from the catalog and register with the model so search can reveal them.
 */

import type { ReadSignal } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { motion } from "@inline/ui/tokens/motion.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { type ReactNode, useId } from "react"
import { itemSpec, type SettingsItemId } from "./catalog"
import { BoundToggle } from "./controls"
import type { SettingsModel } from "./settings-model"

export function Section(props: { title: string; description?: string; children: ReactNode }) {
  const id = useId()
  return (
    <section aria-labelledby={id} {...stylex.props(styles.section)}>
      <h2 id={id} {...stylex.props(styles.sectionTitle)}>
        {props.title}
      </h2>
      {props.description ? <p {...stylex.props(styles.sectionDescription)}>{props.description}</p> : null}
      <div {...stylex.props(styles.group)}>{props.children}</div>
    </section>
  )
}

export type RowIds = { readonly titleId: string; readonly descriptionId: string | undefined }

export function Row(props: {
  model: SettingsModel
  item: SettingsItemId
  description?: ReactNode
  /** The control. Gets the row's title and description IDs for `aria-labelledby` and `aria-describedby`. */
  control?: (ids: RowIds) => ReactNode
  /** Put the control under the title (wide controls like the theme grid). */
  stacked?: boolean
  /** Content under the title and description, before a stacked control (status text). */
  children?: ReactNode
}) {
  const id = useId()
  const titleId = `${id}-title`
  const descriptionId = props.description ? `${id}-description` : undefined
  const highlighted = useSignal(props.model.isHighlighted(props.item))
  const ref = useElement(props.model.row(props.item))
  return (
    <div
      ref={ref}
      data-settings-item={props.item}
      {...stylex.props(styles.row, props.stacked && styles.rowStacked, highlighted && styles.rowHighlighted)}
    >
      <div {...stylex.props(styles.text, props.stacked && styles.textStacked)}>
        <span id={titleId} {...stylex.props(styles.title)}>
          {itemSpec(props.item).title}
        </span>
        {props.description ? (
          <span id={descriptionId} {...stylex.props(styles.description)}>
            {props.description}
          </span>
        ) : null}
        {props.children}
      </div>
      {props.control ? (
        <div {...stylex.props(styles.control, props.stacked && styles.controlStacked)}>
          {props.control({ titleId, descriptionId })}
        </div>
      ) : null}
    </div>
  )
}

/** An on/off switch over a setting's signal (kit `ToggleController`, `role="switch"`). */
export function SettingSwitch(props: {
  value: ReadSignal<boolean>
  onChange: (on: boolean) => void
  ids: RowIds
  disabled?: boolean
}) {
  const bound = useModel(() => new BoundToggle(props.value, props.onChange, { disabled: props.disabled ?? false }), [
    props.value,
    props.disabled,
  ])
  const on = useSignal(bound.toggle.pressed)
  return (
    <button
      type="button"
      ref={useElement(bound.toggle.root)}
      aria-labelledby={props.ids.titleId}
      aria-describedby={props.ids.descriptionId}
      {...stylex.props(styles.track, on && styles.trackOn, props.disabled && styles.disabled)}
    >
      <span {...stylex.props(styles.thumb, on && styles.thumbOn)} />
    </button>
  )
}

/** Plain secondary text in a row (a status, a value). */
export function Note(props: { children: ReactNode; tone?: "normal" | "warning" | "strong"; live?: boolean }) {
  return (
    <span
      aria-live={props.live ? "polite" : undefined}
      {...stylex.props(styles.note, props.tone === "warning" && styles.noteWarning, props.tone === "strong" && styles.noteStrong)}
    >
      {props.children}
    </span>
  )
}

const styles = stylex.create({
  section: { display: "flex", flexDirection: "column", gap: space.sm },
  sectionTitle: {
    margin: 0,
    paddingInline: space.md,
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
  },
  sectionDescription: {
    margin: 0,
    paddingInline: space.md,
    fontSize: font.sizeCallout,
    color: color.secondaryLabel,
  },
  group: {
    display: "flex",
    flexDirection: "column",
    borderRadius: radius.content,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    overflow: "hidden",
  },
  row: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    flexWrap: "wrap",
    gap: space.lg,
    minBlockSize: size.controlLarge,
    paddingBlock: space.md,
    paddingInline: space.lg,
    borderBlockStartWidth: { default: "1px", ":first-child": "0" },
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
    backgroundColor: "transparent",
    transitionProperty: "background-color",
    transitionDuration: motion.durationSlow,
    scrollMarginBlock: space.huge,
  },
  rowStacked: { flexDirection: "column", alignItems: "stretch", gap: space.md },
  rowHighlighted: { backgroundColor: color.unemphasizedSelectedContentBackground },
  // flexBasis is a width only in a side-by-side row; in a stacked (column) row it would become a 220px height.
  text: { display: "flex", flexDirection: "column", gap: space.xxs, minInlineSize: 0, flexGrow: 1, flexBasis: "220px" },
  textStacked: { flexGrow: 0, flexBasis: "auto" },
  title: { fontSize: font.sizeBody, color: color.label },
  description: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  control: { display: "flex", alignItems: "center", gap: space.md, flexShrink: 0, flexWrap: "wrap" },
  // Stacked: the control takes the row's full width, so a wide control (the theme grid) lays out its own columns.
  controlStacked: { display: "block", flexShrink: 1, inlineSize: "100%", minInlineSize: 0 },
  note: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  noteWarning: { color: color.orange },
  noteStrong: { color: color.label, fontWeight: font.weightMedium },
  // The switch, as the kit's Switch draws it, with the label kept on the row's leading side.
  track: {
    position: "relative",
    flexShrink: 0,
    inlineSize: "32px",
    blockSize: "18px",
    padding: 0,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
    cursor: "default",
    transitionProperty: "background-color",
    transitionDuration: motion.durationFast,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  trackOn: { backgroundColor: color.accent, borderColor: color.accent },
  disabled: { opacity: 0.5 },
  thumb: {
    position: "absolute",
    insetBlockStart: "1px",
    insetInlineStart: "1px",
    inlineSize: "14px",
    blockSize: "14px",
    borderRadius: radius.pill,
    backgroundColor: color.onAccent,
    boxShadow: "0 1px 2px rgba(0, 0, 0, 0.3)",
    transitionProperty: "inset-inline-start",
    transitionDuration: motion.durationFast,
  },
  thumbOn: { insetInlineStart: "15px" },
})
