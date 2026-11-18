/**
 * The full emoji picker's view: search with the skin tone selector, the
 * virtualized grid, a preview line and the category bar. Renders
 * `EmojiPickerController`; every behavior is there. Only the rows that
 * intersect the viewport (plus two on each side) are in the DOM, positioned
 * by transform inside a spacer of the full height; a highlight move
 * re-renders the two rows involved.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import { memo } from "react"
import { emojiTokens } from "./emoji.stylex"
import type { GridRow } from "./grid"
import type { EmojiPickerController, PickerItem } from "./picker"
import { SKIN_TONE_LABELS, SKIN_TONES } from "./tone"

export function EmojiPicker(props: { controller: EmojiPickerController }) {
  const { controller } = props
  return (
    <div data-emoji-picker="" {...stylex.props(styles.root)}>
      <SearchBar controller={controller} />
      <GridArea controller={controller} />
      <PreviewLine controller={controller} />
      <TabBar controller={controller} />
    </div>
  )
}

/** The picker's box while its data loads, so the popover does not change size when it arrives. */
export function EmojiPickerPlaceholder() {
  return (
    <div data-emoji-picker="" aria-busy="true" {...stylex.props(styles.root)}>
      <div {...stylex.props(styles.searchBar)} />
      <div {...stylex.props(styles.scroller, styles.placeholder)}>Loading…</div>
      <div {...stylex.props(styles.preview)} />
      <div {...stylex.props(styles.tabs)} />
    </div>
  )
}

function SearchBar(props: { controller: EmojiPickerController }) {
  const { controller } = props
  const searchRef = useElement(controller.search)
  const toneOpen = useSignal(controller.toneMenuOpen)
  const tone = useSignal(controller.skinTone)
  const sample = controller.toneSamples.find((entry) => entry.tone === tone)?.emoji ?? "✋"
  return (
    <div {...stylex.props(styles.searchBar)}>
      <input ref={searchRef} type="search" placeholder="Search emoji" aria-label="Search emoji" {...stylex.props(styles.search)} />
      {toneOpen ? (
        <div role="radiogroup" aria-label="Skin tone" {...stylex.props(styles.tones)}>
          {SKIN_TONES.map((choice) => (
            <ToneChoice key={choice} controller={controller} tone={choice} />
          ))}
        </div>
      ) : (
        <IconButton
          label={`Skin tone: ${SKIN_TONE_LABELS[tone]}`}
          aria-haspopup="true"
          aria-expanded={false}
          onClick={() => controller.openToneMenu()}
          icon={
            <span aria-hidden="true" {...stylex.props(styles.emojiText, styles.toneGlyph)}>
              {sample}
            </span>
          }
        />
      )}
    </div>
  )
}

function ToneChoice(props: { controller: EmojiPickerController; tone: (typeof SKIN_TONES)[number] }) {
  const ref = useElement(props.controller.toneChoice(props.tone))
  const sample = props.controller.toneSamples.find((entry) => entry.tone === props.tone)?.emoji ?? "✋"
  return (
    <button ref={ref} type="button" aria-label={SKIN_TONE_LABELS[props.tone]} {...stylex.props(styles.toneChoice, styles.focusRing)}>
      <span aria-hidden="true" {...stylex.props(styles.emojiText, styles.toneGlyph)}>
        {sample}
      </span>
    </button>
  )
}

function GridArea(props: { controller: EmojiPickerController }) {
  const { controller } = props
  const gridRef = useElement(controller.grid)
  const layout = useSignal(controller.layout)
  const range = useSignal(controller.window)
  const sections = useSignal(controller.sections)
  const empty = useSignal(controller.isEmpty)
  const inset = useSignal(controller.inset)
  const rows = layout.rows.slice(range.start, range.end)
  return (
    <div ref={gridRef} {...stylex.props(styles.scroller, styles.focusRingInset)}>
      {empty ? (
        <div role="row" aria-rowindex={1} {...stylex.props(styles.emptyRow)}>
          <div role="gridcell">No Results</div>
        </div>
      ) : null}
      <div role="presentation" {...stylex.props(styles.spacer, dynamic.height(layout.height))}>
        {rows.map((row, offset) =>
          row.kind === "header" ? (
            <HeaderRow key={row.key} row={row} title={sections[row.section]?.title ?? ""} rowIndex={range.start + offset + 1} columns={layout.columns} inset={inset} />
          ) : (
            <CellRow
              key={row.key}
              controller={controller}
              row={row}
              items={sections[row.section]?.items ?? none}
              rowIndex={range.start + offset + 1}
              inset={inset}
            />
          ),
        )}
      </div>
    </div>
  )
}

const none: readonly PickerItem[] = []

const HeaderRow = memo(function HeaderRow(props: { row: GridRow; title: string; rowIndex: number; columns: number; inset: number }) {
  return (
    <div role="row" aria-rowindex={props.rowIndex} {...stylex.props(styles.row, styles.headerRow, dynamic.place(props.row.top, props.inset))}>
      <div role="rowheader" aria-colspan={props.columns} {...stylex.props(styles.headerText)}>
        {props.title}
      </div>
    </div>
  )
})

const CellRow = memo(function CellRow(props: {
  controller: EmojiPickerController
  row: Extract<GridRow, { kind: "cells" }>
  items: readonly PickerItem[]
  rowIndex: number
  inset: number
}) {
  const { controller, row } = props
  const highlighted = useSignal(controller.rowHighlight(row.section, row.start, row.count))
  const cells = props.items.slice(row.start, row.start + row.count)
  return (
    <div role="row" aria-rowindex={props.rowIndex} {...stylex.props(styles.row, styles.cellRow, dynamic.place(row.top, props.inset))}>
      {cells.map((item, offset) => (
        <div
          key={item.id}
          id={controller.cellId({ section: row.section, item: row.start + offset })}
          role="gridcell"
          aria-colindex={offset + 1}
          aria-selected={highlighted === offset}
          aria-label={item.info.label}
          data-section={row.section}
          data-item={row.start + offset}
          {...stylex.props(styles.cell, styles.emojiText, highlighted === offset && styles.cellActive)}
        >
          {item.emoji}
        </div>
      ))}
    </div>
  )
})

function PreviewLine(props: { controller: EmojiPickerController }) {
  const item = useSignal(props.controller.preview)
  return (
    <div id={props.controller.previewId} {...stylex.props(styles.preview)}>
      {item ? (
        <>
          <span aria-hidden="true" {...stylex.props(styles.emojiText, styles.previewGlyph)}>
            {item.emoji}
          </span>
          <span {...stylex.props(styles.previewName)}>{item.info.label}</span>
          <span dir="ltr" {...stylex.props(styles.previewCode)}>
            :{item.info.shortcode}:
          </span>
        </>
      ) : (
        <span {...stylex.props(styles.previewHint)}>Pick an emoji</span>
      )}
    </div>
  )
}

function TabBar(props: { controller: EmojiPickerController }) {
  const { controller } = props
  const ref = useElement(controller.tabBar)
  const active = useSignal(controller.activeTab)
  const stop = active ?? 0
  return (
    <div ref={ref} {...stylex.props(styles.tabs)}>
      {controller.tabs.map((tab) => (
        <IconButton
          key={tab.id}
          label={tab.title}
          size="small"
          data-tab-index={tab.index}
          tabIndex={tab.index === stop ? 0 : -1}
          aria-current={active === tab.index ? "true" : undefined}
          onClick={() => controller.selectTab(tab.index)}
          style={[styles.tab, active === tab.index && styles.tabActive]}
          icon={
            <span aria-hidden="true" {...stylex.props(styles.emojiText, styles.tabGlyph, active === tab.index && styles.tabGlyphActive)}>
              {tab.glyph}
            </span>
          }
        />
      ))}
    </div>
  )
}

const dynamic = stylex.create({
  height: (height: number) => ({ blockSize: `${height}px` }),
  place: (top: number, inset: number) => ({ transform: `translateY(${top}px)`, paddingInline: `${inset}px` }),
})

const styles = stylex.create({
  root: {
    display: "flex",
    flexDirection: "column",
    inlineSize: `min(${emojiTokens.pickerWidth}, var(--ui-available-width, 100vw))`,
    maxInlineSize: "100%",
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  emojiText: {
    fontFamily: emojiTokens.fontFamily,
    fontVariantEmoji: "emoji",
    fontStyle: "normal",
    fontWeight: font.weightRegular,
    lineHeight: 1,
  },
  focusRing: {
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  focusRingInset: {
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: `calc(-1 * ${size.focusRingWidth})`,
  },
  searchBar: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    blockSize: emojiTokens.searchBar,
    paddingInline: space.lg,
    boxSizing: "border-box",
    borderBlockEndWidth: space.hairline,
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
    flexShrink: 0,
  },
  search: {
    flexGrow: 1,
    minInlineSize: 0,
    blockSize: size.controlSmall,
    paddingInline: space.md,
    boxSizing: "border-box",
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    backgroundColor: color.textBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    "::placeholder": { color: color.placeholderText },
  },
  tones: {
    display: "flex",
    gap: space.xxs,
    flexShrink: 0,
  },
  toneChoice: {
    display: "grid",
    placeItems: "center",
    inlineSize: emojiTokens.toneSwatch,
    blockSize: emojiTokens.toneSwatch,
    padding: 0,
    borderStyle: "none",
    borderRadius: radius.control,
    backgroundColor: { default: "transparent", ":hover": color.controlHover, ":is([aria-checked=true])": color.selectedContentBackground },
    cursor: "pointer",
  },
  toneGlyph: {
    fontSize: font.sizeHeadline,
  },
  scroller: {
    position: "relative",
    blockSize: emojiTokens.gridHeight,
    overflowY: "auto",
    overflowX: "hidden",
    overscrollBehavior: "contain",
    flexShrink: 0,
  },
  placeholder: {
    display: "grid",
    placeItems: "center",
    color: color.secondaryLabel,
  },
  spacer: {
    position: "relative",
    inlineSize: "100%",
  },
  emptyRow: {
    position: "absolute",
    insetInline: 0,
    insetBlockStart: "40%",
    textAlign: "center",
    color: color.secondaryLabel,
  },
  row: {
    position: "absolute",
    insetBlockStart: 0,
    insetInlineStart: 0,
    insetInlineEnd: 0,
    boxSizing: "border-box",
  },
  headerRow: {
    display: "flex",
    alignItems: "center",
    blockSize: emojiTokens.headerHeight,
  },
  headerText: {
    paddingInlineStart: space.xs,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
  },
  cellRow: {
    display: "flex",
    gap: space.xxs,
  },
  cell: {
    display: "grid",
    placeItems: "center",
    inlineSize: emojiTokens.cell,
    blockSize: emojiTokens.cell,
    flexShrink: 0,
    borderRadius: emojiTokens.cellRadius,
    fontSize: emojiTokens.cellFont,
    cursor: "pointer",
    userSelect: "none",
  },
  cellActive: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
    "@media (forced-colors: active)": { outline: `2px solid Highlight` },
  },
  preview: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    blockSize: emojiTokens.previewBar,
    paddingInline: space.lg,
    boxSizing: "border-box",
    borderBlockStartWidth: space.hairline,
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
    flexShrink: 0,
    overflow: "hidden",
    whiteSpace: "nowrap",
  },
  previewGlyph: {
    fontSize: emojiTokens.previewFont,
  },
  previewName: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    minInlineSize: 0,
  },
  previewCode: {
    color: color.secondaryLabel,
    fontSize: font.sizeFootnote,
    overflow: "hidden",
    textOverflow: "ellipsis",
    flexShrink: 1,
    minInlineSize: 0,
  },
  previewHint: {
    color: color.tertiaryLabel,
  },
  tabs: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-evenly",
    blockSize: emojiTokens.categoryBar,
    paddingInline: space.md,
    boxSizing: "border-box",
    borderBlockStartWidth: space.hairline,
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
    flexShrink: 0,
  },
  tab: {
    inlineSize: emojiTokens.categoryButton,
    blockSize: emojiTokens.categoryButton,
    borderRadius: radius.control,
  },
  tabActive: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
  },
  tabGlyph: {
    fontSize: font.sizeCallout,
    filter: "grayscale(1)",
    opacity: 0.7,
  },
  tabGlyphActive: {
    filter: "none",
    opacity: 1,
  },
})
