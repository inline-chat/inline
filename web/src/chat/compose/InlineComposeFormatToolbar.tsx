import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import * as stylex from "@stylexjs/stylex"
import {
  $getSelection,
  $isRangeSelection,
  COMMAND_PRIORITY_LOW,
  FORMAT_TEXT_COMMAND,
  SELECTION_CHANGE_COMMAND,
} from "lexical"
import { useCallback, useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { colors } from "../../styles/tokens.stylex"

type ToolbarState = {
  top: number
  left: number
  bold: boolean
  italic: boolean
}

export function InlineComposeFormatToolbar() {
  const [editor] = useLexicalComposerContext()
  const [toolbar, setToolbar] = useState<ToolbarState>()
  const updateQueued = useRef(false)
  const update = useCallback(() => {
    const root = editor.getRootElement()
    const nativeSelection = window.getSelection()
    editor.getEditorState().read(() => {
      const selection = $getSelection()
      if (
        editor.isComposing() ||
        !root ||
        !$isRangeSelection(selection) ||
        selection.isCollapsed() ||
        !nativeSelection ||
        nativeSelection.rangeCount === 0 ||
        !root.contains(nativeSelection.anchorNode) ||
        !root.contains(nativeSelection.focusNode)
      ) {
        setToolbar(undefined)
        return
      }
      const bounds = nativeSelection.getRangeAt(0).getBoundingClientRect()
      if (!bounds.width && !bounds.height) {
        setToolbar(undefined)
        return
      }
      setToolbar({
        top: Math.max(8, bounds.top - 38),
        left: Math.min(
          window.innerWidth - 48,
          Math.max(48, bounds.left + bounds.width / 2),
        ),
        bold: selection.hasFormat("bold"),
        italic: selection.hasFormat("italic"),
      })
    })
  }, [editor])
  const queueUpdate = useCallback(() => {
    if (updateQueued.current) return
    updateQueued.current = true
    queueMicrotask(() => {
      updateQueued.current = false
      update()
    })
  }, [update])

  useEffect(() => {
    const removeUpdate = editor.registerUpdateListener(queueUpdate)
    const removeSelection = editor.registerCommand(
      SELECTION_CHANGE_COMMAND,
      () => {
        queueUpdate()
        return false
      },
      COMMAND_PRIORITY_LOW,
    )
    window.addEventListener("resize", queueUpdate)
    window.addEventListener("scroll", queueUpdate, true)
    return () => {
      removeUpdate()
      removeSelection()
      window.removeEventListener("resize", queueUpdate)
      window.removeEventListener("scroll", queueUpdate, true)
    }
  }, [editor, queueUpdate])

  if (!toolbar) return null
  return createPortal(
    <div
      role="toolbar"
      aria-label="Text formatting"
      data-inline-compose-format-toolbar
      style={{ top: toolbar.top, left: toolbar.left }}
      {...stylex.props(styles.toolbar)}
    >
      <button
        type="button"
        aria-label="Bold"
        aria-pressed={toolbar.bold}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => editor.dispatchCommand(FORMAT_TEXT_COMMAND, "bold")}
        {...stylex.props(styles.button, toolbar.bold && styles.selected)}
      >
        B
      </button>
      <button
        type="button"
        aria-label="Italic"
        aria-pressed={toolbar.italic}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => editor.dispatchCommand(FORMAT_TEXT_COMMAND, "italic")}
        {...stylex.props(styles.button, styles.italic, toolbar.italic && styles.selected)}
      >
        I
      </button>
    </div>,
    document.body,
  )
}

const styles = stylex.create({
  toolbar: {
    height: 32,
    display: "flex",
    position: "fixed",
    zIndex: 120,
    gap: 2,
    padding: 3,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 8,
    backgroundColor: colors.content,
    boxShadow: `0 6px 20px ${colors.shadow}`,
    transform: "translateX(-50%)",
  },
  button: {
    width: 24,
    height: 24,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderRadius: 5,
    color: colors.textPrimary,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    fontSize: 12,
    fontWeight: 700,
  },
  italic: {
    fontStyle: "italic",
  },
  selected: {
    backgroundColor: colors.selected,
    color: colors.accent,
  },
})
