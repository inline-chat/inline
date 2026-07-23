import { AutoFocusPlugin } from "@lexical/react/LexicalAutoFocusPlugin"
import { LexicalComposer } from "@lexical/react/LexicalComposer"
import { ContentEditable } from "@lexical/react/LexicalContentEditable"
import { LexicalErrorBoundary } from "@lexical/react/LexicalErrorBoundary"
import { HistoryPlugin } from "@lexical/react/LexicalHistoryPlugin"
import { RichTextPlugin } from "@lexical/react/LexicalRichTextPlugin"
import * as stylex from "@stylexjs/stylex"
import { forwardRef, useImperativeHandle, useMemo, useRef } from "react"
import type { LexicalEditor } from "lexical"
import { useLexicalComposerContext } from "@lexical/react/LexicalComposerContext"
import { colors } from "../../styles/tokens.stylex"
import { InlineMentionNode } from "./InlineMentionNode"
import {
  $setInlineComposeDocument,
  inlineComposeDocument,
  type InlineComposeDocument,
} from "./InlineComposeDocument"
import {
  InlineComposeMentionsPlugin,
  InlineComposePlainTextPastePlugin,
  InlineComposeSendPlugin,
  InlineComposeStatePlugin,
  type InlineMentionItem,
} from "./InlineComposePlugins"
import { InlineComposeFormatToolbar } from "./InlineComposeFormatToolbar"

export type InlineComposeEditorHandle = {
  focus: () => void
  clear: () => void
  document: () => InlineComposeDocument
}

function InlineComposeEditorHandlePlugin({
  editorRef,
}: {
  editorRef: React.MutableRefObject<LexicalEditor | null>
}) {
  const [editor] = useLexicalComposerContext()
  editorRef.current = editor
  return null
}

export const InlineComposeEditor = forwardRef<
  InlineComposeEditorHandle,
  {
    value: InlineComposeDocument
    placeholder: string
    mentionItems: readonly InlineMentionItem[]
    onChange: (value: InlineComposeDocument) => void
    onSubmit: (value: InlineComposeDocument) => void
  }
>(function InlineComposeEditor(
  { value, placeholder, mentionItems, onChange, onSubmit },
  ref,
) {
  const editor = useRef<LexicalEditor | null>(null)
  useImperativeHandle(ref, () => ({
    focus: () => editor.current?.focus(),
    document: () =>
      editor.current
        ? inlineComposeDocument(editor.current.getEditorState())
        : value,
    clear: () =>
      editor.current?.update(
        () => $setInlineComposeDocument({ text: "" }),
        { tag: "inline-draft-clear" },
      ),
  }))
  const initialValue = useRef(value).current
  const initialConfig = useMemo(
    () => ({
      namespace: "InlineCompose",
      nodes: [InlineMentionNode],
      editorState: initialValue.text
        ? () => $setInlineComposeDocument(initialValue)
        : undefined,
      theme: {
        text: {
          bold: "InlineCompose__bold",
          italic: "InlineCompose__italic",
        },
      },
      onError: (error: Error) => {
        throw error
      },
    }),
    [initialValue],
  )

  return (
    <LexicalComposer initialConfig={initialConfig}>
      <RichTextPlugin
        contentEditable={
          <ContentEditable
            aria-label="Message"
            data-inline-compose-editor
            {...stylex.props(styles.editor)}
          />
        }
        placeholder={
          <span {...stylex.props(styles.placeholder)}>
            {placeholder}
          </span>
        }
        ErrorBoundary={LexicalErrorBoundary}
      />
      <HistoryPlugin />
      <AutoFocusPlugin />
      <InlineComposeStatePlugin value={value} onChange={onChange} />
      <InlineComposeSendPlugin onSubmit={onSubmit} />
      <InlineComposePlainTextPastePlugin />
      <InlineComposeMentionsPlugin items={mentionItems} />
      <InlineComposeFormatToolbar />
      <InlineComposeEditorHandlePlugin editorRef={editor} />
    </LexicalComposer>
  )
})

const styles = stylex.create({
  editor: {
    width: "100%",
    minWidth: 0,
    minHeight: 28,
    maxHeight: 144,
    flex: 1,
    overflowY: "auto",
    paddingBlock: 6,
    outline: 0,
    color: colors.textPrimary,
    fontSize: 13,
    lineHeight: 1.25,
    whiteSpace: "pre-wrap",
  },
  placeholder: {
    position: "absolute",
    left: 10,
    bottom: 12,
    pointerEvents: "none",
    color: colors.textTertiary,
    fontSize: 13,
    lineHeight: 1.25,
  },
})
