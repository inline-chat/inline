/** Views for Listbox, Combobox and Tabs. */

import * as stylex from "@stylexjs/stylex"
import { useElement, useSignal } from "@inline/reactive/react"
import type { ReactNode } from "react"
import type { ComboboxController } from "../combobox/controller"
import type { ListboxController, ListboxOption } from "../listbox/controller"
import type { TabsController } from "../tabs/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { radius } from "../tokens/radius.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"
import { CheckIcon } from "./icons"
import { shared } from "./styles"

/** A focusable listbox. Rows read their own state, so a selection change re-renders only the rows it touches. */
export function Listbox(props: { controller: ListboxController; style?: stylex.StyleXStyles; renderOption?: (option: ListboxOption) => ReactNode }) {
  const items = useSignal(props.controller.items)
  const ref = useElement(props.controller.root)
  return (
    <div ref={ref} {...stylex.props(styles.listbox, shared.focusRing, props.style)}>
      {items.map((option) => (
        <OptionRow key={option.id} controller={props.controller} option={option} render={props.renderOption} />
      ))}
    </div>
  )
}

function OptionRow(props: { controller: ListboxController; option: ListboxOption; render?: (option: ListboxOption) => ReactNode; inPopup?: boolean }) {
  const ref = useElement(props.controller.option(props.option.id))
  const active = useSignal(props.controller.isActive(props.option.id))
  const selected = useSignal(props.controller.isSelected(props.option.id))
  const multiple = props.controller.selection.mode === "multiple"
  return (
    <div
      ref={ref}
      {...stylex.props(
        styles.option,
        selected && !props.inPopup && styles.selected,
        active && (props.inPopup ? styles.popupActive : styles.active),
        props.option.disabled && styles.disabled,
      )}
    >
      {(multiple || props.inPopup) && (
        <span aria-hidden="true" {...stylex.props(styles.check)}>
          {selected ? <CheckIcon size={14} /> : null}
        </span>
      )}
      <span {...stylex.props(styles.optionText)}>{props.render ? props.render(props.option) : props.option.label}</span>
    </div>
  )
}

/** A text field with a filtered listbox popup. */
export function Combobox(props: { controller: ComboboxController; label: string; placeholder?: string; emptyText?: string }) {
  const { controller } = props
  const inputRef = useElement(controller.input)
  return (
    <div {...stylex.props(styles.combobox)}>
      <input
        ref={inputRef}
        aria-label={props.label}
        placeholder={props.placeholder}
        dir="auto"
        {...stylex.props(styles.input)}
      />
      <ComboboxPopup controller={controller} emptyText={props.emptyText ?? "No results"} />
    </div>
  )
}

function ComboboxPopup(props: { controller: ComboboxController; emptyText: string }) {
  const { controller } = props
  const popupRef = useElement(controller.popup)
  const listRef = useElement(controller.listbox.passiveRoot)
  const results = useSignal(controller.results)
  const status = useSignal(controller.status)
  return (
    <div ref={popupRef} popover="manual" {...stylex.props(shared.layerReset, shared.menuSurface, styles.popup)}>
      <div ref={listRef}>
        {results.map((option) => (
          <OptionRow key={option.id} controller={controller.listbox} option={option} inPopup />
        ))}
      </div>
      {results.length === 0 && status !== "loading" && <div {...stylex.props(styles.status)}>{props.emptyText}</div>}
      {status === "loading" && <div {...stylex.props(styles.status)}>Searching…</div>}
      {status === "error" && <div {...stylex.props(styles.status, styles.error)}>Could not load results</div>}
    </div>
  )
}

/** Tabs with their panels. `renderPanel` is called for the selected tab only. */
export function Tabs(props: {
  controller: TabsController
  tabs: ReadonlyArray<{ id: string; label: string }>
  renderPanel: (id: string) => ReactNode
}) {
  const listRef = useElement(props.controller.list)
  const selected = useSignal(props.controller.selectedId)
  return (
    <div {...stylex.props(styles.tabs)}>
      <div ref={listRef} {...stylex.props(styles.tabList)}>
        {props.tabs.map((tab) => (
          <Tab key={tab.id} controller={props.controller} id={tab.id} label={tab.label} />
        ))}
      </div>
      {props.tabs.map((tab) => (
        <Panel key={tab.id} controller={props.controller} id={tab.id}>
          {selected === tab.id ? props.renderPanel(tab.id) : null}
        </Panel>
      ))}
    </div>
  )
}

function Tab(props: { controller: TabsController; id: string; label: string }) {
  const ref = useElement(props.controller.tab(props.id))
  const selected = useSignal(props.controller.isSelected(props.id))
  return (
    <button type="button" ref={ref} {...stylex.props(styles.tab, shared.focusRing, selected && styles.tabSelected)}>
      {props.label}
    </button>
  )
}

function Panel(props: { controller: TabsController; id: string; children: ReactNode }) {
  const ref = useElement(props.controller.panel(props.id))
  return (
    <div ref={ref} {...stylex.props(styles.panel, shared.focusRing)}>
      {props.children}
    </div>
  )
}

const styles = stylex.create({
  listbox: {
    display: "flex",
    flexDirection: "column",
    gap: "1px",
    padding: space.xs,
    overflowY: "auto",
    borderRadius: radius.control,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
  },
  option: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    minHeight: size.menuItem,
    paddingInline: space.md,
    borderRadius: radius.menuItem,
    color: color.label,
    cursor: "default",
    userSelect: "none",
  },
  selected: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
  },
  active: {
    outline: `1px solid ${color.focusRing}`,
    outlineOffset: "-1px",
  },
  popupActive: {
    backgroundColor: color.selectedMenuItem,
    color: color.selectedMenuItemText,
  },
  disabled: { color: color.disabledText },
  check: { display: "inline-flex", width: "14px", flexShrink: 0 },
  optionText: { flexGrow: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  combobox: { display: "flex", flexDirection: "column", minWidth: 0 },
  input: {
    boxSizing: "border-box",
    height: size.control,
    paddingInline: space.md,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    color: color.label,
    backgroundColor: color.textBackground,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
  },
  popup: { width: "var(--ui-anchor-width, auto)", minWidth: "var(--ui-anchor-width, 180px)" },
  status: { paddingInline: space.md, paddingBlock: space.sm, color: color.secondaryLabel, fontSize: font.sizeCallout },
  error: { color: color.red },
  tabs: { display: "flex", flexDirection: "column", gap: space.md },
  tabList: {
    display: "inline-flex",
    alignSelf: "flex-start",
    gap: space.xxs,
    padding: space.xxs,
    borderRadius: radius.control,
    backgroundColor: color.controlTrack,
  },
  tab: {
    height: size.controlSmall,
    paddingInline: space.lg,
    borderStyle: "none",
    borderRadius: radius.small,
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    cursor: "default",
  },
  tabSelected: {
    backgroundColor: { default: color.control, ":hover": color.control },
    boxShadow: `0 0.5px 1px ${color.controlBorder}`,
    fontWeight: font.weightMedium,
  },
  panel: { minHeight: 0, borderRadius: radius.control },
})
