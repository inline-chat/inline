import { ContextMenu } from "@base-ui/react/context-menu"
import * as stylex from "@stylexjs/stylex"
import {
  Fragment,
  useRef,
  type ComponentPropsWithoutRef,
  type ReactNode,
} from "react"
import { colors } from "../styles/tokens.stylex"

export type InlineContextMenuItem = {
  label: string
  onSelect: () => void
  disabled?: boolean
  destructive?: boolean
  separatorBefore?: boolean
}

type InlineContextMenuProps = ComponentPropsWithoutRef<"div"> & {
  children: ReactNode
  items: readonly InlineContextMenuItem[]
}

/**
 * App-owned boundary around the browser menu primitive. Feature views provide
 * Inline actions and labels; positioning, long press, and keyboard navigation
 * stay isolated here.
 */
export function InlineContextMenu({
  children,
  items,
  onKeyDown,
  ...triggerProps
}: InlineContextMenuProps) {
  const popupRef = useRef<HTMLDivElement>(null)
  const keyboardOpenRef = useRef(false)
  const openFromKeyboard: ComponentPropsWithoutRef<"div">["onKeyDown"] = (
    event,
  ) => {
    onKeyDown?.(event)
    if (
      event.defaultPrevented ||
      !(
        event.key === "ContextMenu" ||
        (event.key === "F10" && event.shiftKey)
      )
    ) {
      return
    }
    event.preventDefault()
    keyboardOpenRef.current = true
    const bounds = event.currentTarget.getBoundingClientRect()
    event.currentTarget.dispatchEvent(
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: bounds.left + Math.min(bounds.width / 2, 24),
        clientY: bounds.top + Math.min(bounds.height / 2, 24),
      }),
    )
  }

  return (
    <ContextMenu.Root
      onOpenChangeComplete={(open) => {
        if (!open) {
          keyboardOpenRef.current = false
          return
        }
        if (!keyboardOpenRef.current) return
        keyboardOpenRef.current = false
        // Base UI receives a synthetic contextmenu event so the app can offer
        // Shift-F10 consistently. That event otherwise looks pointer-opened
        // and leaves focus on the trigger. Complete the keyboard contract only
        // after Base UI has mounted and positioned its popup.
        popupRef.current
          ?.querySelector<HTMLElement>(
            '[role="menuitem"]:not([aria-disabled="true"])',
          )
          ?.focus()
      }}
    >
      <ContextMenu.Trigger {...triggerProps} onKeyDown={openFromKeyboard}>
        {children}
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        <ContextMenu.Positioner {...stylex.props(styles.positioner)}>
          <ContextMenu.Popup ref={popupRef} {...stylex.props(styles.popup)}>
            {items.map((item) => (
              <Fragment key={item.label}>
                {item.separatorBefore ? (
                  <ContextMenu.Separator {...stylex.props(styles.separator)} />
                ) : null}
                <ContextMenu.Item
                  disabled={item.disabled}
                  onClick={item.onSelect}
                  className={({ disabled, highlighted }) =>
                    stylex.props(
                      styles.item,
                      highlighted && styles.highlighted,
                      disabled && styles.disabled,
                      item.destructive && styles.destructive,
                    ).className
                  }
                >
                  {item.label}
                </ContextMenu.Item>
              </Fragment>
            ))}
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}

const styles = stylex.create({
  positioner: {
    zIndex: 100,
    outline: "none",
  },
  popup: {
    minWidth: 176,
    padding: 4,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 8,
    backgroundColor: colors.content,
    boxShadow: `0 8px 28px ${colors.shadow}`,
    color: colors.textPrimary,
    outline: "none",
  },
  item: {
    minHeight: 26,
    display: "flex",
    alignItems: "center",
    paddingInline: 9,
    borderRadius: 5,
    color: colors.textPrimary,
    fontSize: 12,
    lineHeight: "26px",
    outline: "none",
    cursor: "default",
    userSelect: "none",
    ":hover": {
      backgroundColor: colors.selected,
    },
    ":focus": {
      backgroundColor: colors.selected,
    },
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
  separator: {
    height: 1,
    marginBlock: 4,
    marginInline: 5,
    backgroundColor: colors.separator,
  },
})
