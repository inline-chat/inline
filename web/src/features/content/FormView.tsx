/**
 * A form block (Mac `RichBlockFormNodeView`): the field kinds the model
 * defines, one submit through `onSubmitForm`. The answers live in a
 * `FormController` for the life of the view. A secret field is a password
 * input that never starts filled and is emptied after the submit, so a
 * submitted secret is never shown back.
 */

import * as stylex from "@stylexjs/stylex"
import {
  type FormAnswer,
  type FormBlock,
  type FormFieldNode,
  type FormOptionNode,
  formButtonLabel,
  type FormSession,
} from "@inline/chat-ui"
import { useModel, useSignal } from "@inline/reactive/react"
import { Button, Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { useId } from "react"
import { FormController, formLockReason } from "./form-controller"
import { contentText, RichTextView } from "./RichText"
import type { RowContent } from "./row-content"

export function FormView(props: { block: FormBlock; ctx: RowContent }) {
  const { block, ctx } = props
  const submit = ctx.env.handlers.onSubmitForm
  const controller = useModel(
    () =>
      new FormController(
        block,
        submit ? (values) => submit({ rowId: ctx.rowId, formId: block.formId, values }) : undefined,
      ),
    [ctx, block.formId],
  )
  const session = useSignal(controller.session)
  const error = useSignal(controller.error)
  const lock = formLockReason(block, ctx.env.canUse)
  const editable = lock === undefined && controller.editable(block)
  const sending = session.phase === "submitting"
  const statusId = useId()
  const set = (fieldId: string, answer: FormAnswer) => controller.setAnswer(block, fieldId, answer)

  return (
    <form
      noValidate
      dir={block.dir ?? "auto"}
      aria-describedby={error || lock ? statusId : undefined}
      onSubmit={(event) => {
        event.preventDefault()
        if (editable) void controller.submit(block)
      }}
      {...stylex.props(styles.form)}
    >
      {block.title && (
        <div {...stylex.props(styles.title)}>
          <RichTextView text={block.title} ctx={ctx} />
        </div>
      )}
      {block.fields.map((field) => (
        <Field key={field.key} field={field} session={session} editable={editable} ctx={ctx} onAnswer={set} />
      ))}
      <div {...stylex.props(styles.footer)}>
        <Button type="submit" variant="primary" size="small" disabled={!editable || sending}>
          {sending && <Progress variant="spinner" label="Sending" />}
          {formButtonLabel(block, session)}
        </Button>
        {(error ?? lock) && (
          <span id={statusId} role={error ? "alert" : undefined} {...stylex.props(styles.status, error !== undefined && styles.error)}>
            {error ?? lock}
          </span>
        )}
      </div>
    </form>
  )
}

function Field(props: {
  field: FormFieldNode
  session: FormSession
  editable: boolean
  ctx: RowContent
  onAnswer: (fieldId: string, answer: FormAnswer) => void
}) {
  const { field, session, editable, ctx, onAnswer } = props
  const labelId = useId()
  const descriptionId = useId()
  const answer = session.answers[field.fieldId]
  const input = field.input
  const describedBy = field.description ? descriptionId : undefined
  const label = (
    <span id={labelId} {...stylex.props(styles.label)}>
      <RichTextView text={field.label} ctx={ctx} />
      {field.required && (
        <span aria-hidden="true" {...stylex.props(styles.required)}>
          {" *"}
        </span>
      )}
    </span>
  )
  const description = field.description && (
    <span id={descriptionId} {...stylex.props(contentText.caption, contentText.secondary)}>
      <RichTextView text={field.description} ctx={ctx} />
    </span>
  )

  let control
  switch (input.kind) {
    case "text": {
      const value = answer?.kind === "text" ? answer.value : ""
      const common = {
        "aria-labelledby": labelId,
        "aria-describedby": describedBy,
        "aria-required": field.required || undefined,
        disabled: !editable,
        maxLength: input.maxLength,
        placeholder: input.placeholder,
        value,
      }
      control =
        input.style === "multiline" ? (
          <textarea
            {...common}
            rows={3}
            dir="auto"
            onChange={(event) => onAnswer(field.fieldId, { kind: "text", value: event.currentTarget.value })}
            {...stylex.props(styles.input, styles.textarea)}
          />
        ) : (
          <input
            {...common}
            type={input.style === "secret" ? "password" : "text"}
            autoComplete="off"
            spellCheck={input.style === "secret" ? false : undefined}
            dir="auto"
            onChange={(event) => onAnswer(field.fieldId, { kind: "text", value: event.currentTarget.value })}
            {...stylex.props(styles.input)}
          />
        )
      break
    }
    case "number": {
      const value = answer?.kind === "number" && answer.value !== undefined ? String(answer.value) : ""
      control = (
        <input
          type="number"
          inputMode={input.integer ? "numeric" : "decimal"}
          aria-labelledby={labelId}
          aria-describedby={describedBy}
          aria-required={field.required || undefined}
          disabled={!editable}
          min={input.min}
          max={input.max}
          step={input.integer ? Math.max(1, Math.round(input.step)) : input.step}
          value={value}
          onChange={(event) => {
            const raw = event.currentTarget.value
            const parsed = raw.trim() === "" ? undefined : Number(raw)
            onAnswer(field.fieldId, {
              kind: "number",
              value: parsed !== undefined && Number.isFinite(parsed) ? parsed : undefined,
            })
          }}
          {...stylex.props(styles.input, styles.number)}
        />
      )
      break
    }
    case "toggle": {
      const checked = answer?.kind === "toggle" ? answer.value : input.defaultValue
      return (
        <label {...stylex.props(styles.field, styles.toggleRow)}>
          <input
            type="checkbox"
            role="switch"
            aria-describedby={describedBy}
            disabled={!editable}
            checked={checked}
            onChange={(event) => onAnswer(field.fieldId, { kind: "toggle", value: event.currentTarget.checked })}
            {...stylex.props(styles.check)}
          />
          <span {...stylex.props(styles.toggleText)}>
            {label}
            {description}
          </span>
        </label>
      )
    }
    case "select": {
      const selection = answer?.kind === "selection" ? answer : { kind: "selection" as const, optionIds: [] as readonly string[] }
      control =
        input.presentation === "menu" && !input.multiple ? (
          <select
            aria-labelledby={labelId}
            aria-describedby={describedBy}
            aria-required={field.required || undefined}
            disabled={!editable}
            value={selection.optionIds[0] ?? ""}
            onChange={(event) =>
              onAnswer(field.fieldId, {
                kind: "selection",
                optionIds: event.currentTarget.value ? [event.currentTarget.value] : [],
              })
            }
            {...stylex.props(styles.input)}
          >
            <option value="">Choose…</option>
            {input.options.map((option) => (
              <option key={option.key} value={option.optionId}>
                {option.label.document.text}
                {option.recommended ? " (Recommended)" : ""}
              </option>
            ))}
          </select>
        ) : (
          <div role={input.multiple ? "group" : "radiogroup"} aria-labelledby={labelId} aria-describedby={describedBy} {...stylex.props(styles.options)}>
            {input.options.map((option) => (
              <OptionRow
                key={option.key}
                option={option}
                name={`${field.key}:${labelId}`}
                multiple={input.multiple}
                checked={selection.optionIds.includes(option.optionId)}
                disabled={!editable}
                ctx={ctx}
                onChange={(checked) => {
                  const ids = input.multiple
                    ? checked
                      ? [...selection.optionIds, option.optionId]
                      : selection.optionIds.filter((id) => id !== option.optionId)
                    : [option.optionId]
                  onAnswer(field.fieldId, {
                    kind: "selection",
                    optionIds: ids,
                    ...(input.multiple && selection.otherText ? { otherText: selection.otherText } : {}),
                  })
                }}
              />
            ))}
          </div>
        )
      if (input.allowOther) {
        control = (
          <>
            {control}
            <input
              type="text"
              aria-label="Your answer"
              placeholder="Your answer"
              dir="auto"
              disabled={!editable}
              value={selection.otherText ?? ""}
              onChange={(event) => {
                const otherText = event.currentTarget.value
                onAnswer(field.fieldId, {
                  kind: "selection",
                  // A single choice is either an option or "Other".
                  optionIds: input.multiple || otherText.trim() === "" ? selection.optionIds : [],
                  otherText,
                })
              }}
              {...stylex.props(styles.input)}
            />
          </>
        )
      }
      break
    }
  }

  return (
    <div {...stylex.props(styles.field)}>
      {field.header && (
        <div {...stylex.props(styles.header)}>
          <RichTextView text={field.header} ctx={ctx} />
        </div>
      )}
      {label}
      {description}
      {control}
    </div>
  )
}

function OptionRow(props: {
  option: FormOptionNode
  name: string
  multiple: boolean
  checked: boolean
  disabled: boolean
  ctx: RowContent
  onChange: (checked: boolean) => void
}) {
  const { option } = props
  return (
    <label {...stylex.props(styles.option, props.checked && styles.optionChecked)}>
      <input
        type={props.multiple ? "checkbox" : "radio"}
        name={props.name}
        value={option.optionId}
        checked={props.checked}
        disabled={props.disabled}
        onChange={(event) => props.onChange(event.currentTarget.checked)}
        {...stylex.props(styles.check)}
      />
      <span {...stylex.props(styles.optionText)}>
        <span {...stylex.props(styles.optionLabel)}>
          <RichTextView text={option.label} ctx={props.ctx} />
          {option.recommended && <span {...stylex.props(styles.recommended)}>Recommended</span>}
        </span>
        {option.description && (
          <span {...stylex.props(contentText.caption, contentText.secondary)}>
            <RichTextView text={option.description} ctx={props.ctx} />
          </span>
        )}
        {option.preview && (
          <code dir="ltr" {...stylex.props(contentText.mono, styles.preview)}>
            {option.preview}
          </code>
        )}
      </span>
    </label>
  )
}

const styles = stylex.create({
  form: {
    display: "flex",
    flexDirection: "column",
    gap: space.md,
    minInlineSize: "220px",
    margin: 0,
    paddingBlock: space.md,
    paddingInline: space.md,
    borderRadius: radius.content,
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.separator,
    backgroundColor: color.textBackground,
    color: color.label,
  },
  title: { fontWeight: font.weightSemibold },
  field: { display: "flex", flexDirection: "column", gap: space.xs, minInlineSize: 0 },
  header: { fontSize: font.sizeCallout, fontWeight: font.weightSemibold, color: color.secondaryLabel },
  label: { fontWeight: font.weightMedium },
  required: { color: color.destructive },
  input: {
    minInlineSize: 0,
    blockSize: "28px",
    paddingInline: space.md,
    boxSizing: "border-box",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.controlBorder,
    borderRadius: radius.control,
    backgroundColor: color.control,
    color: color.controlText,
    fontFamily: "inherit",
    fontSize: font.sizeBody,
    outline: { default: "none", ":focus-visible": `2px solid ${color.focusRing}` },
    opacity: { default: 1, ":disabled": 0.6 },
  },
  textarea: { blockSize: "auto", minBlockSize: "56px", paddingBlock: space.xs, resize: "vertical" },
  number: { inlineSize: "120px" },
  options: { display: "flex", flexDirection: "column", gap: space.xxs },
  option: {
    display: "flex",
    alignItems: "flex-start",
    gap: space.sm,
    paddingBlock: space.xs,
    paddingInline: space.sm,
    borderRadius: radius.control,
    cursor: "pointer",
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
  },
  optionChecked: { backgroundColor: `color-mix(in srgb, ${color.accent} 10%, transparent)` },
  check: { margin: 0, marginBlockStart: "2px", accentColor: color.accent, flexShrink: 0 },
  optionText: { display: "flex", flexDirection: "column", gap: "1px", minInlineSize: 0 },
  optionLabel: { display: "flex", alignItems: "baseline", gap: space.sm, flexWrap: "wrap" },
  recommended: {
    paddingInline: space.xs,
    borderRadius: radius.small,
    fontSize: font.sizeFootnote,
    fontWeight: font.weightMedium,
    color: color.accent,
    backgroundColor: `color-mix(in srgb, ${color.accent} 12%, transparent)`,
  },
  preview: { whiteSpace: "pre-wrap", color: color.secondaryLabel },
  toggleRow: { flexDirection: "row", alignItems: "flex-start", gap: space.sm, cursor: "pointer" },
  toggleText: { display: "flex", flexDirection: "column", gap: "1px" },
  footer: { display: "flex", alignItems: "center", flexWrap: "wrap", gap: space.md },
  status: { fontSize: font.sizeCallout, color: color.secondaryLabel },
  error: { color: color.destructive },
})
