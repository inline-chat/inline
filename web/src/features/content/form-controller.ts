/**
 * A form block's answers and its one submit, over `chat-ui`'s pure session
 * functions (`blocks/form.ts`). The session lives in memory only, for the
 * life of the view: secret answers are never written anywhere, and after a
 * successful submit they are dropped, so the form never shows one back.
 */

import {
  beginSubmit,
  type FormAnswer,
  type FormBlock,
  type FormSession,
  type FormSubmissionValue,
  grantReason,
  initialFormSession,
  isFormEditable,
  setFormAnswer,
  submitFailed,
  submitSucceeded,
} from "@inline/chat-ui"
import type { GrantRequirement } from "@inline/core-protocol"
import { type ReadSignal, signal } from "@inline/reactive"

/** Sends the values; resolves when the server accepted them, rejects otherwise. */
export type FormSubmit = (values: readonly FormSubmissionValue[]) => Promise<void>

export const formSendFailedText = "Couldn’t send your answers. Try again."
export const formUnavailableText = "This form can’t be answered here"

export class FormController {
  readonly #session: ReturnType<typeof signal<FormSession>>
  readonly #error = signal<string | undefined>(undefined)
  readonly #submit: FormSubmit | undefined
  #disposed = false

  constructor(form: FormBlock, submit: FormSubmit | undefined) {
    this.#session = signal(initialFormSession(form))
    this.#submit = submit
  }

  get session(): ReadSignal<FormSession> {
    return this.#session
  }

  /** The message under the button: a required field left empty, or a failed send. */
  get error(): ReadSignal<string | undefined> {
    return this.#error
  }

  get canSubmit(): boolean {
    return this.#submit !== undefined
  }

  /** Takes input: open, editing, and a submit handler exists. */
  editable(form: FormBlock): boolean {
    return this.#submit !== undefined && isFormEditable(form, this.#session.peek())
  }

  setAnswer(form: FormBlock, fieldId: string, answer: FormAnswer): void {
    if (!this.#submit) return
    const next = setFormAnswer(form, this.#session.peek(), fieldId, answer)
    if (next === this.#session.peek()) return
    this.#session.set(next)
    if (this.#error.peek() !== undefined) this.#error.set(undefined)
  }

  /** The one submit. Ignored while sending, after success, or on a closed form. */
  async submit(form: FormBlock): Promise<void> {
    const submit = this.#submit
    if (!submit) return
    const result = beginSubmit(form, this.#session.peek())
    if (!result.ok) {
      if (result.error) this.#error.set(result.error)
      return
    }
    this.#session.set(result.session)
    this.#error.set(undefined)
    try {
      await submit(result.values)
      if (this.#disposed) return
      this.#session.set(submitSucceeded(form, this.#session.peek()))
    } catch {
      if (this.#disposed) return
      this.#session.set(submitFailed(this.#session.peek()))
      this.#error.set(formSendFailedText)
    }
  }

  dispose(): void {
    this.#disposed = true
  }
}

/**
 * Why the viewer cannot answer, or undefined when they can. `canUse` is the
 * app's grant check; without one, everyone can.
 */
export const formLockReason = (
  form: Pick<FormBlock, "requiredGrant" | "closed">,
  canUse: ((grant: GrantRequirement) => boolean) | undefined,
  names?: { owner?: string; agent?: string },
): string | undefined => {
  if (form.closed) return undefined
  if (form.requiredGrant && canUse && !canUse(form.requiredGrant)) return grantReason(form.requiredGrant, names)
  return undefined
}
