import * as stylex from "@stylexjs/stylex"
import { useElement, useSignal } from "@inline/reactive/react"
import type { ReactNode } from "react"
import type { ContextMenuController } from "../context-menu/controller"
import type { MenuController, MenuEntry } from "../menu/controller"
import { color } from "../tokens/color.stylex"
import { font } from "../tokens/font.stylex"
import { radius } from "../tokens/radius.stylex"
import { size } from "../tokens/size.stylex"
import { space } from "../tokens/space.stylex"
import { Button, type ButtonProps } from "./Button"
import { CheckIcon, ChevronDownIcon, ChevronIcon, DotIcon } from "./icons"
import { shared } from "./styles"

/**
 * A menu's content: rendered only while open, in the top layer. Submenus
 * render as siblings of their item, inside this content (no portals).
 */
export function MenuContent(props: { menu: MenuController }) {
  const open = useSignal(props.menu.isOpen)
  if (!open) return null
  return <OpenMenu menu={props.menu} />
}

function OpenMenu(props: { menu: MenuController }) {
  const entries = useSignal(props.menu.entries)
  const ref = useElement(props.menu.content)
  const hasIndicators = entries.some((entry) => entry.type === "checkbox" || entry.type === "radio")
  return (
    <div ref={ref} popover="manual" {...stylex.props(shared.layerReset, shared.menuSurface)}>
      {entries.map((entry) => (
        <MenuEntryView key={entry.id} menu={props.menu} entry={entry} indent={hasIndicators} />
      ))}
    </div>
  )
}

function MenuEntryView(props: { menu: MenuController; entry: MenuEntry; indent: boolean }) {
  const { entry } = props
  if (entry.type === "separator") return <Separator menu={props.menu} id={entry.id} />
  if (entry.type === "label") return <Label menu={props.menu} id={entry.id} label={entry.label} />
  if (entry.type === "submenu") {
    return (
      <>
        <MenuItemView menu={props.menu} entry={entry} indent={props.indent} />
        <MenuContent menu={props.menu.submenu(entry.id)} />
      </>
    )
  }
  return <MenuItemView menu={props.menu} entry={entry} indent={props.indent} />
}

function Separator(props: { menu: MenuController; id: string }) {
  const ref = useElement(props.menu.item(props.id))
  return <div ref={ref} {...stylex.props(shared.separator)} />
}

function Label(props: { menu: MenuController; id: string; label: string }) {
  const ref = useElement(props.menu.item(props.id))
  return (
    <div ref={ref} {...stylex.props(styles.label)}>
      {props.label}
    </div>
  )
}

function MenuItemView(props: { menu: MenuController; entry: Exclude<MenuEntry, { type: "separator" | "label" }>; indent: boolean }) {
  const { entry } = props
  const ref = useElement(props.menu.item(entry.id))
  const highlighted = useSignal(props.menu.isHighlighted(entry.id))
  const openSubmenu = useSignal(props.menu.openSubmenuId)
  const active = highlighted
  const checked = (entry.type === "checkbox" || entry.type === "radio") && entry.checked
  const destructive = entry.type === "item" && entry.destructive
  return (
    <div
      ref={ref}
      {...stylex.props(
        styles.item,
        active && styles.highlighted,
        entry.type === "submenu" && openSubmenu === entry.id && !highlighted && styles.submenuOpen,
        destructive && !active && styles.destructive,
        entry.disabled && styles.disabled,
      )}
    >
      {props.indent && (
        <span aria-hidden="true" {...stylex.props(styles.indicator)}>
          {checked ? entry.type === "radio" ? <DotIcon size={14} /> : <CheckIcon size={14} /> : null}
        </span>
      )}
      <span {...stylex.props(styles.text)}>{entry.label}</span>
      {"shortcut" in entry && entry.shortcut && (
        <span aria-hidden="true" {...stylex.props(styles.shortcut, active && styles.shortcutActive)}>
          {entry.shortcut}
        </span>
      )}
      {entry.type === "submenu" && <ChevronIcon size={12} style={styles.chevron} />}
    </div>
  )
}

export type MenuButtonProps = Omit<ButtonProps, "ref"> & { menu: MenuController; children: ReactNode }

/** A button that opens a menu (APG "Menu Button"), with its content. */
export function MenuButton({ menu, children, ...rest }: MenuButtonProps) {
  const ref = useElement(menu.trigger)
  return (
    <>
      <Button {...rest} ref={ref}>
        {children}
        <ChevronDownIcon size={12} />
      </Button>
      <MenuContent menu={menu} />
    </>
  )
}

/** A region that opens a context menu on secondary click, long press or the context menu key. */
export function ContextMenuArea(props: { controller: ContextMenuController; children: ReactNode; style?: stylex.StyleXStyles }) {
  const ref = useElement(props.controller.target)
  return (
    <div ref={ref} {...stylex.props(props.style)}>
      {props.children}
      <MenuContent menu={props.controller.menu} />
    </div>
  )
}

const styles = stylex.create({
  item: {
    display: "flex",
    alignItems: "center",
    gap: space.sm,
    minHeight: size.menuItem,
    paddingInline: space.md,
    boxSizing: "border-box",
    borderRadius: radius.menuItem,
    color: color.label,
    fontSize: font.sizeBody,
    outline: "none",
    cursor: "default",
  },
  highlighted: {
    backgroundColor: color.selectedMenuItem,
    color: color.selectedMenuItemText,
  },
  submenuOpen: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
  },
  destructive: { color: color.destructive },
  disabled: { color: color.disabledText },
  indicator: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    width: "14px",
    flexShrink: 0,
  },
  text: { flexGrow: 1, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" },
  shortcut: {
    marginInlineStart: space.xl,
    color: color.tertiaryLabel,
    fontSize: font.sizeBody,
    letterSpacing: "0.04em",
  },
  shortcutActive: { color: color.selectedMenuItemText, opacity: 0.85 },
  chevron: { marginInlineStart: space.md, opacity: 0.7 },
  label: {
    paddingInline: space.md,
    paddingBlock: space.xs,
    fontSize: font.sizeCallout,
    fontWeight: font.weightSemibold,
    color: color.secondaryLabel,
  },
})
