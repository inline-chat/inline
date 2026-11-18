/**
 * Part of the autocomplete chunk (`autocomplete-chunk.ts`), loaded on the
 * first trigger; `ComposerView` renders it once the chunk and the cursor
 * are here.
 *
 * The autocomplete popup: a `popover="manual"` layer placed at the trigger
 * character by the model's `popup` part, holding the UI kit listbox in its
 * passive form (focus stays in the editor, which points at the active row
 * with `aria-activedescendant`). Rows read their own active state, so moving
 * the cursor re-renders two rows.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { Avatar } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { shadow } from "@inline/ui/tokens/shadow.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { AutocompleteCursor, ComposerSuggestion } from "./autocomplete"
import { composerSize } from "./composer.stylex"
import type { ComposerModel } from "./model"

const listLabels = { mention: "People", emoji: "Emoji", command: "Commands" } as const

export function AutocompletePopup(props: { model: ComposerModel; cursor: AutocompleteCursor }) {
  const autocomplete = props.model.autocomplete
  const popupRef = useElement(props.model.popup)
  const listRef = useElement(props.cursor.listbox.passiveRoot)
  const rows = useSignal(autocomplete.suggestions)
  const kind = useSignal(autocomplete.kind)
  return (
    <div ref={popupRef} popover="manual" {...stylex.props(styles.popup)}>
      <div ref={listRef} aria-label={kind ? listLabels[kind] : "Suggestions"} {...stylex.props(styles.list)}>
        {rows.map((row) => (
          <SuggestionRow key={row.id} cursor={props.cursor} row={row} />
        ))}
      </div>
    </div>
  )
}

function SuggestionRow(props: { cursor: AutocompleteCursor; row: ComposerSuggestion }) {
  const { row } = props
  const ref = useElement(props.cursor.listbox.option(row.id))
  const active = useSignal(props.cursor.listbox.isActive(row.id))
  return (
    <div ref={ref} {...stylex.props(styles.row, active && styles.rowActive)}>
      {row.avatar ? (
        // The row's title names it; the avatar is decoration here.
        <span aria-hidden="true" {...stylex.props(styles.avatar)}>
          <Avatar
            name={row.avatar.name}
            size="small"
            {...(row.avatar.seed !== undefined ? { seed: row.avatar.seed } : {})}
            {...(row.avatar.src !== undefined ? { src: row.avatar.src } : {})}
          />
        </span>
      ) : row.glyph ? (
        <span aria-hidden="true" {...stylex.props(styles.glyph)}>
          {row.glyph}
        </span>
      ) : null}
      <span dir="auto" {...stylex.props(styles.title)}>
        {row.title}
      </span>
      {row.subtitle ? (
        <span dir="auto" {...stylex.props(styles.subtitle, active && styles.subtitleActive)}>
          {row.subtitle}
        </span>
      ) : null}
    </div>
  )
}

const styles = stylex.create({
  popup: {
    // The popover element's UA box, reset; the model's part writes the position.
    margin: 0,
    padding: space.xs,
    borderStyle: "none",
    boxSizing: "border-box",
    inlineSize: `min(${composerSize.suggestionsWidth}, var(--ui-available-width, 100vw))`,
    maxBlockSize: `min(${composerSize.suggestionsMaxHeight}, var(--ui-available-height, 50vh))`,
    overflowY: "auto",
    overscrollBehavior: "contain",
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    backgroundColor: color.menuBackground,
    backdropFilter: "blur(24px) saturate(1.6)",
    borderRadius: radius.menu,
    boxShadow: shadow.menu,
    userSelect: "none",
  },
  list: { display: "flex", flexDirection: "column", gap: "1px", outline: "none" },
  row: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    minBlockSize: composerSize.suggestionRow,
    paddingInline: space.md,
    borderRadius: radius.menuItem,
    cursor: "default",
  },
  rowActive: {
    backgroundColor: color.selectedMenuItem,
    color: color.selectedMenuItemText,
  },
  avatar: { display: "inline-flex", flexShrink: 0 },
  glyph: { inlineSize: "20px", textAlign: "center", fontSize: font.sizeTitle3, flexShrink: 0 },
  title: {
    flexShrink: 1,
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    fontWeight: font.weightMedium,
  },
  subtitle: {
    flexShrink: 2,
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
  },
  subtitleActive: { color: "inherit", opacity: 0.8 },
})
