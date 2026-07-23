import {
  LexicalTypeaheadMenuPlugin,
  MenuOption,
  useBasicTypeaheadTriggerMatch,
} from "@lexical/react/LexicalTypeaheadMenuPlugin"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import {
  $createTextNode,
  $getSelection,
  $getRoot,
  $isRangeSelection,
  $isTextNode,
  COMMAND_PRIORITY_CRITICAL,
  COMMAND_PRIORITY_HIGH,
  KEY_ENTER_COMMAND,
  PASTE_COMMAND,
} from "lexical"
import * as stylex from "@stylexjs/stylex"
import {
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import { createPortal } from "react-dom"
import type { UserID } from "@inline/ids"
import { colors } from "../../styles/tokens.stylex"
import {
  $createInlineMentionNode,
} from "./InlineMentionNode"
import {
  $setInlineComposeDocument,
  inlineComposeDocument,
  type InlineComposeDocument,
} from "./InlineComposeDocument"

export type InlineMentionItem = {
  userId: UserID
  name: string
}

class InlineMentionOption extends MenuOption {
  constructor(readonly item: InlineMentionItem) {
    super(String(item.userId))
  }
}

export function InlineComposeMentionsPlugin({
  items,
}: {
  items: readonly InlineMentionItem[]
}) {
  const [editor] = useLexicalComposerContext()
  const trigger = useBasicTypeaheadTriggerMatch("@", {
    minLength: 0,
    maxLength: 75,
  })
  const [query, setQuery] = useState<string | null>(null)
  const options = useMemo(() => {
    const normalized = query?.trim().toLocaleLowerCase() ?? ""
    return items
      .filter((item) =>
        item.name.toLocaleLowerCase().includes(normalized),
      )
      .slice(0, 6)
      .map((item) => new InlineMentionOption(item))
  }, [items, query])

  return (
    <LexicalTypeaheadMenuPlugin<InlineMentionOption>
      triggerFn={trigger}
      onQueryChange={setQuery}
      options={options}
      onSelectOption={(option, _node, close) => {
        editor.update(() => {
          const mention = $createInlineMentionNode(
            `@${option.item.name}`,
            option.item.userId,
          )
          const selection = $getSelection()
          if ($isRangeSelection(selection)) {
            const replaceLength = (query?.length ?? 0) + 1
            const endNode = selection.anchor.getNode()
            if ($isTextNode(endNode)) {
              const endOffset = selection.anchor.offset
              const textNodes = $getRoot().getAllTextNodes()
              let nodeIndex = textNodes.indexOf(endNode)
              let startNode = endNode
              let startOffset = endOffset
              let remaining = replaceLength
              while (remaining > startOffset && nodeIndex > 0) {
                remaining -= startOffset
                nodeIndex -= 1
                startNode = textNodes[nodeIndex]!
                startOffset = startNode.getTextContentSize()
              }
              if (remaining <= startOffset) {
                startOffset -= remaining
                selection.setTextNodeRange(
                  startNode,
                  startOffset,
                  endNode,
                  endOffset,
                )
                selection.insertNodes([
                  mention,
                  $createTextNode(" "),
                ])
              }
            }
          }
          close()
        })
      }}
      menuRenderFn={(anchor, menu) =>
        anchor.current && options.length > 0
          ? createPortal(
              <ul
                role="listbox"
                data-inline-compose-mention-menu
                {...stylex.props(styles.mentionMenu)}
              >
                {options.map((option, index) => (
                  <li
                    key={option.key}
                    ref={option.setRefElement}
                    role="option"
                    aria-selected={menu.selectedIndex === index}
                    onMouseEnter={() => menu.setHighlightedIndex(index)}
                    onMouseDown={(event) => event.preventDefault()}
                    onClick={() => menu.selectOptionAndCleanUp(option)}
                    {...stylex.props(
                      styles.mentionItem,
                      menu.selectedIndex === index &&
                        styles.mentionItemSelected,
                    )}
                  >
                    {option.item.name}
                  </li>
                ))}
              </ul>,
              anchor.current,
            )
          : null
      }
    />
  )
}

export function InlineComposeStatePlugin({
  value,
  onChange,
}: {
  value: InlineComposeDocument
  onChange: (value: InlineComposeDocument) => void
}) {
  const [editor] = useLexicalComposerContext()
  const applied = useRef(false)
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange

  useLayoutEffect(() => {
    if (applied.current || !value.text) return
    const current = inlineComposeDocument(
      editor.getEditorState(),
    ).text
    if (current) return
    applied.current = true
    editor.update(
      () => $setInlineComposeDocument(value),
      { tag: "inline-draft-restore" },
    )
  }, [editor, value])

  useEffect(
    () =>
      editor.registerUpdateListener(({ editorState, tags }) => {
        if (
          tags.has("inline-draft-restore") ||
          tags.has("inline-draft-clear")
        ) {
          return
        }
        onChangeRef.current(inlineComposeDocument(editorState))
      }),
    [editor],
  )
  return null
}

export function InlineComposeSendPlugin({
  onSubmit,
}: {
  onSubmit: (value: InlineComposeDocument) => void
}) {
  const [editor] = useLexicalComposerContext()
  const onSubmitRef = useRef(onSubmit)
  onSubmitRef.current = onSubmit
  useEffect(
    () =>
      editor.registerCommand(
        KEY_ENTER_COMMAND,
        (event) => {
          if (
            !event ||
            event.shiftKey ||
            event.isComposing ||
            event.keyCode === 229 ||
            editor.isComposing() ||
            document.querySelector(
              "[data-inline-compose-mention-menu]",
            )
          ) {
            return false
          }
          event.preventDefault()
          onSubmitRef.current(
            inlineComposeDocument(editor.getEditorState()),
          )
          return true
        },
        COMMAND_PRIORITY_HIGH,
      ),
    [editor],
  )
  return null
}

export function InlineComposePlainTextPastePlugin() {
  const [editor] = useLexicalComposerContext()
  useEffect(
    () =>
      editor.registerCommand(
        PASTE_COMMAND,
        (event) => {
          const transfer =
            "clipboardData" in event
              ? event.clipboardData
              : "dataTransfer" in event
                ? event.dataTransfer
                : null
          if (!transfer) return false
          const selection = $getSelection()
          if (!$isRangeSelection(selection)) return false
          event.preventDefault()
          selection.insertText(
            transfer.getData("text/plain").replace(/\r\n?/g, "\n"),
          )
          return true
        },
        COMMAND_PRIORITY_CRITICAL,
      ),
    [editor],
  )
  return null
}

const styles = stylex.create({
  mentionMenu: {
    minWidth: 180,
    maxWidth: 280,
    maxHeight: 220,
    overflowY: "auto",
    zIndex: 100,
    margin: 0,
    padding: 4,
    listStyle: "none",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.separator,
    borderRadius: 8,
    backgroundColor: colors.control,
    boxShadow: "0 8px 24px rgba(0,0,0,.14)",
  },
  mentionItem: {
    paddingBlock: 6,
    paddingInline: 8,
    borderRadius: 5,
    fontSize: 12,
  },
  mentionItemSelected: {
    backgroundColor: colors.selected,
  },
})
