import {
  AgentGrantRequirement,
  BlockFormText_Kind,
  type Block,
  type BlockContent,
  type BlockForm,
  type BlockFormField,
  type BlockText,
  type MessageFormSubmission,
  type MessageFormValue,
} from "@inline-chat/protocol/core"
import { RealtimeRpcError } from "@in/server/realtime/errors"

export const messageFormLimits = {
  maxFormsPerMessage: 4,
  maxFields: 32,
  maxOptions: 64,
  maxIdLength: 64,
  maxLabelLength: 64,
  maxPlaceholderLength: 256,
  maxTextLength: 16_384,
  maxOtherTextLength: 1_024,
}

/** Same identifiers as MessageAction.action_id. */
export const messageFormIdPattern = /^[a-zA-Z0-9_.:-]+$/

function validId(id: string): boolean {
  return id.length >= 1 && id.length <= messageFormLimits.maxIdLength && messageFormIdPattern.test(id)
}

function fieldMaxLength(field: BlockFormField): number {
  if (field.kind.oneofKind !== "text") return messageFormLimits.maxTextLength
  return Math.min(field.kind.text.maxLength ?? messageFormLimits.maxTextLength, messageFormLimits.maxTextLength)
}

/** Structural checks for a form definition; text ranges are checked by the caller. */
export function validateFormDefinition(form: BlockForm, validateText: (range: BlockText | undefined) => void): void {
  if (!validId(form.formId)) throw new Error("Invalid form id")
  if (form.title) validateText(form.title)
  if ((form.submitLabel?.length ?? 0) > messageFormLimits.maxLabelLength) throw new Error("Form submit label is too long")
  if (form.requiredGrant < AgentGrantRequirement.NONE || form.requiredGrant > AgentGrantRequirement.OWNER) {
    throw new Error("Invalid form grant requirement")
  }
  if (form.fields.length === 0 || form.fields.length > messageFormLimits.maxFields) throw new Error("Invalid form fields")

  const fieldIds = new Set<string>()
  for (const field of form.fields) {
    if (!validId(field.fieldId) || fieldIds.has(field.fieldId)) throw new Error("Invalid form field id")
    fieldIds.add(field.fieldId)
    validateText(field.label)
    if (field.description) validateText(field.description)

    switch (field.kind.oneofKind) {
      case "select": {
        const select = field.kind.select
        if (select.options.length > messageFormLimits.maxOptions) throw new Error("Too many form options")
        if (select.options.length === 0 && !select.allowOther) throw new Error("Form select has no options")
        const optionIds = new Set<string>()
        for (const option of select.options) {
          if (!validId(option.optionId) || optionIds.has(option.optionId)) throw new Error("Invalid form option id")
          optionIds.add(option.optionId)
          validateText(option.label)
          if (option.description) validateText(option.description)
        }
        const defaults = new Set(select.defaultOptionIds)
        if (defaults.size !== select.defaultOptionIds.length || [...defaults].some((id) => !optionIds.has(id))) {
          throw new Error("Invalid form select default")
        }
        if (!select.multiple && defaults.size > 1) throw new Error("Single select has several defaults")
        break
      }
      case "text": {
        const text = field.kind.text
        if (text.kind < BlockFormText_Kind.SINGLE_LINE || text.kind > BlockFormText_Kind.SECRET) {
          throw new Error("Invalid form text kind")
        }
        if (text.maxLength !== undefined && (text.maxLength < 1 || text.maxLength > messageFormLimits.maxTextLength)) {
          throw new Error("Invalid form text length")
        }
        if ((text.placeholder?.length ?? 0) > messageFormLimits.maxPlaceholderLength) throw new Error("Form placeholder is too long")
        if (text.defaultValue !== undefined) {
          if (text.kind === BlockFormText_Kind.SECRET) throw new Error("Secret fields have no default")
          if (text.defaultValue.length > fieldMaxLength(field)) throw new Error("Form default is too long")
        }
        break
      }
      case "toggle":
        break
      case "number": {
        const number = field.kind.number
        const values = [number.defaultValue, number.min, number.max, number.step]
        if (values.some((value) => value !== undefined && !Number.isFinite(value))) throw new Error("Invalid form number")
        if (number.min !== undefined && number.max !== undefined && number.min > number.max) throw new Error("Invalid form number range")
        if (number.step !== undefined && number.step <= 0) throw new Error("Invalid form number step")
        if (number.defaultValue !== undefined && !numberAllowed(field, number.defaultValue)) throw new Error("Invalid form number default")
        break
      }
      default:
        throw new Error("Missing form field kind")
    }
  }
}

function numberAllowed(field: BlockFormField, value: number): boolean {
  if (field.kind.oneofKind !== "number") return false
  const number = field.kind.number
  if (!Number.isFinite(value)) return false
  if (number.integer && !Number.isInteger(value)) return false
  if (number.min !== undefined && value < number.min) return false
  if (number.max !== undefined && value > number.max) return false
  return true
}

function visitForms(blocks: readonly Block[], visit: (form: BlockForm) => void): void {
  for (const block of blocks) {
    switch (block.kind.oneofKind) {
      case "form":
        visit(block.kind.form)
        break
      case "disclosure":
        visitForms(block.kind.disclosure.children, visit)
        break
      case "quote":
        visitForms(block.kind.quote.children, visit)
        break
      case "callout":
        visitForms(block.kind.callout.children, visit)
        break
      case "list":
        for (const item of block.kind.list.items) visitForms(item.children, visit)
        break
    }
  }
}

export function collectForms(content: BlockContent | null | undefined): BlockForm[] {
  const forms: BlockForm[] = []
  if (content) visitForms(content.blocks, (form) => forms.push(form))
  return forms
}

export function findForm(content: BlockContent | null | undefined, formId: string): BlockForm | undefined {
  return collectForms(content).find((form) => form.formId === formId)
}

export type ValidatedFormSubmission = {
  /** Delivered live to the bot, secrets included. */
  live: MessageFormSubmission
  /** Stored and replayed: secret values removed and marked redacted. */
  stored: MessageFormSubmission
}

function isSecret(field: BlockFormField): boolean {
  return field.kind.oneofKind === "text" && field.kind.text.kind === BlockFormText_Kind.SECRET
}

function isEmpty(value: MessageFormValue): boolean {
  switch (value.value.oneofKind) {
    case "text":
      return value.value.text.trim().length === 0
    case "selection":
      return value.value.selection.optionIds.length === 0 && !(value.value.selection.otherText?.trim())
    case "toggle":
    case "number":
      return false
    default:
      return true
  }
}

/** Checks values against the form's own fields; never logs values. */
export function validateFormSubmission(form: BlockForm, submission: MessageFormSubmission): ValidatedFormSubmission {
  if (form.closed) throw RealtimeRpcError.BadRequest()
  const fields = new Map(form.fields.map((field) => [field.fieldId, field]))
  const seen = new Set<string>()
  const live: MessageFormValue[] = []
  const stored: MessageFormValue[] = []

  for (const value of submission.values) {
    const field = fields.get(value.fieldId)
    if (!field || seen.has(value.fieldId) || value.redacted) throw RealtimeRpcError.BadRequest()
    seen.add(value.fieldId)

    switch (field.kind.oneofKind) {
      case "text":
        if (value.value.oneofKind !== "text" || value.value.text.length > fieldMaxLength(field)) throw RealtimeRpcError.BadRequest()
        if (field.kind.text.kind === BlockFormText_Kind.SINGLE_LINE && /[\r\n]/.test(value.value.text)) {
          throw RealtimeRpcError.BadRequest()
        }
        break
      case "select": {
        if (value.value.oneofKind !== "selection") throw RealtimeRpcError.BadRequest()
        const { optionIds, otherText } = value.value.selection
        const options = new Set(field.kind.select.options.map((option) => option.optionId))
        if (new Set(optionIds).size !== optionIds.length || optionIds.some((id) => !options.has(id))) {
          throw RealtimeRpcError.BadRequest()
        }
        const answers = optionIds.length + (otherText?.trim() ? 1 : 0)
        if (!field.kind.select.multiple && answers > 1) throw RealtimeRpcError.BadRequest()
        if (otherText !== undefined &&
          (!field.kind.select.allowOther || otherText.length > messageFormLimits.maxOtherTextLength)) {
          throw RealtimeRpcError.BadRequest()
        }
        break
      }
      case "toggle":
        if (value.value.oneofKind !== "toggle") throw RealtimeRpcError.BadRequest()
        break
      case "number":
        if (value.value.oneofKind !== "number" || !numberAllowed(field, value.value.number)) throw RealtimeRpcError.BadRequest()
        break
      default:
        throw RealtimeRpcError.BadRequest()
    }

    const normalized: MessageFormValue = { fieldId: value.fieldId, value: value.value, redacted: false }
    live.push(normalized)
    stored.push(isSecret(field)
      ? { fieldId: value.fieldId, value: { oneofKind: undefined }, redacted: true }
      : normalized)
  }

  for (const field of form.fields) {
    if (!field.required) continue
    const value = live.find((candidate) => candidate.fieldId === field.fieldId)
    if (!value || isEmpty(value)) throw RealtimeRpcError.BadRequest()
  }
  return { live: { values: live }, stored: { values: stored } }
}
