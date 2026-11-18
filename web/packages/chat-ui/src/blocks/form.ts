/**
 * Form answers and the one-submit rule (`InlineKit/Agents/MessageForms.swift`,
 * `RichBlockFormNodeView.swift`).
 *
 * - A form is answered once: `beginSubmit` succeeds only from `editing` on an
 *   open form, and moves to `submitting`. Success moves to `submitted` and
 *   drops every secret answer; failure returns to `editing`.
 * - A closed form is read-only and shows the defaults as its answers.
 * - Secret fields never start with a value and are never shown back: their
 *   answers live only in this in-memory session, never in a row, a draft or
 *   storage, and are gone after the submit.
 * - Submission: empty answers are left out, except toggles, which are always
 *   sent. A required field left empty stops the submit with
 *   "Answer “<label>” first".
 *
 * Pure: every function returns a new session. The view keeps the session in
 * memory only, keyed by the message and form.
 */

import type { FormBlock, FormFieldNode } from "./types"

export type FormAnswer =
  | { readonly kind: "text"; readonly value: string }
  | { readonly kind: "selection"; readonly optionIds: readonly string[]; readonly otherText?: string }
  | { readonly kind: "toggle"; readonly value: boolean }
  | { readonly kind: "number"; readonly value: number | undefined }

export type FormPhase = "editing" | "submitting" | "submitted"

export type FormSession = {
  readonly formId: string
  readonly phase: FormPhase
  readonly answers: Readonly<Record<string, FormAnswer>>
}

/** A submitted value, mirroring `MessageFormValue` in the proto. */
export type FormSubmissionValue = {
  readonly fieldId: string
  readonly value:
    | { readonly kind: "text"; readonly text: string }
    | { readonly kind: "selection"; readonly optionIds: readonly string[]; readonly otherText?: string }
    | { readonly kind: "toggle"; readonly value: boolean }
    | { readonly kind: "number"; readonly value: number }
}

const defaultAnswer = (field: FormFieldNode): FormAnswer => {
  const input = field.input
  switch (input.kind) {
    case "select":
      return { kind: "selection", optionIds: input.defaultOptionIds }
    case "text":
      return { kind: "text", value: input.style === "secret" ? "" : (input.defaultValue ?? "") }
    case "toggle":
      return { kind: "toggle", value: input.defaultValue }
    case "number":
      return { kind: "number", value: input.defaultValue }
  }
}

/** A new session with the defaults. A closed form starts (and stays) locked. */
export const initialFormSession = (form: FormBlock): FormSession => ({
  formId: form.formId,
  phase: form.closed ? "submitted" : "editing",
  answers: Object.fromEntries(form.fields.map((field) => [field.fieldId, defaultAnswer(field)])),
})

/** Whether the form takes input: open and editing. */
export const isFormEditable = (form: FormBlock, session: FormSession): boolean => !form.closed && session.phase === "editing"

/** Set one answer; ignored unless editable or for an unknown field. Text is cut to `maxLength`. */
export const setFormAnswer = (form: FormBlock, session: FormSession, fieldId: string, answer: FormAnswer): FormSession => {
  if (!isFormEditable(form, session)) return session
  const field = form.fields.find((candidate) => candidate.fieldId === fieldId)
  if (!field) return session
  let value = answer
  if (answer.kind === "text" && field.input.kind === "text" && field.input.maxLength !== undefined) {
    value = { kind: "text", value: Array.from(answer.value).slice(0, field.input.maxLength).join("") }
  }
  return { ...session, answers: { ...session.answers, [fieldId]: value } }
}

const submissionValue = (field: FormFieldNode, answer: FormAnswer | undefined): FormSubmissionValue["value"] | undefined => {
  if (!answer) return undefined
  switch (answer.kind) {
    case "toggle":
      return { kind: "toggle", value: answer.value }
    case "text":
      return answer.value.trim().length > 0 ? { kind: "text", text: answer.value } : undefined
    case "number":
      return answer.value !== undefined && Number.isFinite(answer.value) ? { kind: "number", value: answer.value } : undefined
    case "selection": {
      const other = answer.otherText?.trim()
      if (answer.optionIds.length === 0 && !other) return undefined
      return {
        kind: "selection",
        optionIds: answer.optionIds,
        ...(other && field.input.kind === "select" && field.input.allowOther ? { otherText: other } : {}),
      }
    }
  }
}

export type BeginSubmitResult =
  | { readonly ok: true; readonly session: FormSession; readonly values: readonly FormSubmissionValue[] }
  | { readonly ok: false; readonly session: FormSession; readonly error?: string }

/**
 * Start the one submit. `ok: false` without an error means the form is not
 * editable (closed, already submitting or submitted): do nothing.
 */
export const beginSubmit = (form: FormBlock, session: FormSession): BeginSubmitResult => {
  if (!isFormEditable(form, session)) return { ok: false, session }
  const values: FormSubmissionValue[] = []
  for (const field of form.fields) {
    const value = submissionValue(field, session.answers[field.fieldId])
    if (value === undefined) {
      if (field.required) return { ok: false, session, error: `Answer “${field.labelText}” first` }
      continue
    }
    values.push({ fieldId: field.fieldId, value })
  }
  return { ok: true, session: { ...session, phase: "submitting" }, values }
}

/** The server accepted the submit: lock the form and forget secret answers. */
export const submitSucceeded = (form: FormBlock, session: FormSession): FormSession => {
  const answers: Record<string, FormAnswer> = { ...session.answers }
  for (const field of form.fields) {
    if (field.input.kind === "text" && field.input.style === "secret") answers[field.fieldId] = { kind: "text", value: "" }
  }
  return { ...session, phase: "submitted", answers }
}

/** The submit failed: back to editing, answers kept. */
export const submitFailed = (session: FormSession): FormSession =>
  session.phase === "submitting" ? { ...session, phase: "editing" } : session

/** The button label: "Answered" when closed, "Sent" after a submit, else the form's label. */
export const formButtonLabel = (form: FormBlock, session: FormSession): string =>
  form.closed ? "Answered" : session.phase === "submitted" ? "Sent" : form.submitLabel
