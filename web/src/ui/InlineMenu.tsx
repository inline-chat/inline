import { Menu } from "@base-ui/react/menu"
import * as stylex from "@stylexjs/stylex"
import { Fragment, type ReactElement, type ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"
import { Icon, type IconName } from "./Icon"

export type InlineMenuItem = {
  label: string
  onSelect: () => void
  icon?: IconName
  checked?: boolean
  disabled?: boolean
  destructive?: boolean
  separatorBefore?: boolean
}

const itemClassName = (
  item: InlineMenuItem,
  state: { disabled: boolean; highlighted: boolean },
) =>
  stylex.props(
    styles.item,
    state.highlighted && styles.highlighted,
    state.disabled && styles.disabled,
    item.destructive && styles.destructive,
  ).className

const itemContent = (item: InlineMenuItem) => (
  <>
    <span {...stylex.props(styles.icon)}>
      {item.icon ? <Icon name={item.icon} size={14} /> : null}
    </span>
    <span {...stylex.props(styles.label)}>{item.label}</span>
    <span {...stylex.props(styles.check)}>
      {item.checked ? <Icon name="check" size={13} /> : null}
    </span>
  </>
)

/** Inline-owned menu surface. Product views own actions and labels while Base
 * UI owns focus, dismissal, keyboard navigation, and trigger positioning. */
export function InlineMenu({
  trigger,
  items,
  side = "bottom",
  align = "start",
  children,
}: {
  trigger: ReactElement
  items?: readonly InlineMenuItem[]
  side?: "top" | "bottom" | "left" | "right"
  align?: "start" | "center" | "end"
  children?: ReactNode
}) {
  return (
    <Menu.Root>
      <Menu.Trigger render={trigger} />
      <Menu.Portal>
        <Menu.Positioner
          side={side}
          align={align}
          sideOffset={5}
          {...stylex.props(styles.positioner)}
        >
          <Menu.Popup {...stylex.props(styles.popup)}>
            {items?.map((item) => (
              <Fragment key={item.label}>
                {item.separatorBefore ? (
                  <Menu.Separator {...stylex.props(styles.separator)} />
                ) : null}
                {item.checked == null ? (
                  <Menu.Item
                    disabled={item.disabled}
                    onClick={item.onSelect}
                    className={(state) => itemClassName(item, state)}
                  >
                    {itemContent(item)}
                  </Menu.Item>
                ) : (
                  <Menu.CheckboxItem
                    checked={item.checked}
                    disabled={item.disabled}
                    closeOnClick
                    onCheckedChange={item.onSelect}
                    className={(state) => itemClassName(item, state)}
                  >
                    {itemContent(item)}
                  </Menu.CheckboxItem>
                )}
              </Fragment>
            ))}
            {children}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  )
}

const styles = stylex.create({
  positioner: {
    zIndex: 120,
    outline: "none",
  },
  popup: {
    minWidth: 184,
    maxWidth: 280,
    padding: 4,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 9,
    backgroundColor: colors.content,
    boxShadow: `0 10px 30px ${colors.shadow}`,
    color: colors.textPrimary,
    outline: "none",
  },
  item: {
    minHeight: 28,
    display: "grid",
    gridTemplateColumns: "18px minmax(0, 1fr) 18px",
    alignItems: "center",
    gap: 6,
    paddingInline: 7,
    borderRadius: 6,
    color: colors.textPrimary,
    fontSize: 12,
    outline: "none",
    cursor: "default",
    userSelect: "none",
  },
  highlighted: {
    backgroundColor: colors.selected,
  },
  disabled: {
    color: colors.textTertiary,
  },
  destructive: {
    color: colors.destructive,
  },
  icon: {
    width: 18,
    display: "grid",
    placeItems: "center",
    color: colors.textSecondary,
  },
  label: {
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  check: {
    width: 18,
    display: "grid",
    placeItems: "center",
    color: colors.accent,
  },
  separator: {
    height: 1,
    marginBlock: 4,
    marginInline: 5,
    backgroundColor: colors.separator,
  },
})
