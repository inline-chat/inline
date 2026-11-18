/**
 * The keyboard dispatcher: resolves a key event to a command using the
 * active scopes, and runs it.
 *
 * Scope precedence, first match wins:
 * 1. Layers (menus, dialogs, popovers), most recently pushed first. A modal
 *    layer stops the search: nothing below it resolves while it is open.
 * 2. Focus scopes, innermost first, as the focused region reports them
 *    (for example `["composer"]` or `["timeline"]`).
 * 3. `global`.
 *
 * Rules that apply to every key:
 * - Nothing fires while an input method is composing.
 * - In a text field, a key that could be typing is left to the field (see
 *   `WhileTyping` in `registry.ts`). On Windows and Linux, Ctrl+Alt with a
 *   character is AltGr and is typing.
 * - A held key repeats a command only if the command allows it; otherwise
 *   the repeat is swallowed so it does not fall through to the browser.
 * - A disabled command does not match, so the key falls through to lower
 *   scopes and then to the browser.
 */

import { computed, signal, type ReadSignal } from "@inline/reactive"
import type { Platform } from "./platform"
import type { Binding, Command, CommandRegistry, ScopeId } from "./registry"
import { comboId, eventCombo, isComposingEvent, isPrintableKey, type KeyCombo, type KeyEventLike } from "./shortcut"

export type Resolution =
  | { readonly kind: "command"; readonly command: Command; readonly combo: KeyCombo }
  /** A bound key repeating for a command that does not repeat: consume it, run nothing. */
  | { readonly kind: "swallow"; readonly command: Command }
  /** A character typed outside any text field; the app may move focus to the composer. */
  | { readonly kind: "typeToFocus" }
  | { readonly kind: "none"; readonly reason: "composing" | "modifierOnly" | "unbound" | "typing" | "disabled" }

export type Layer = { readonly scope: ScopeId; readonly modal: boolean }

/** Whether an event target is a place where keys type text. Duck-typed, so it runs without a DOM. */
export const isTextInputTarget = (target: unknown): boolean => {
  if (typeof target !== "object" || target === null) return false
  const element = target as { isContentEditable?: unknown; tagName?: unknown; type?: unknown }
  if (element.isContentEditable === true) return true
  const tag = typeof element.tagName === "string" ? element.tagName.toUpperCase() : ""
  if (tag === "TEXTAREA" || tag === "SELECT") return true
  if (tag !== "INPUT") return false
  const type = typeof element.type === "string" ? element.type.toLowerCase() : "text"
  return !nonTextInputTypes.has(type)
}

const nonTextInputTypes = new Set([
  "button",
  "checkbox",
  "color",
  "file",
  "hidden",
  "image",
  "radio",
  "range",
  "reset",
  "submit",
])

/** Whether a combo can be typing on an OS, given the event (for AltGr). */
export const canBeTyping = (combo: KeyCombo, platform: Platform, event?: KeyEventLike): boolean => {
  if (event?.getModifierState?.("AltGraph")) return true
  const printable = isPrintableKey(combo.key)
  if (combo.ctrl || combo.meta) {
    // AltGr arrives as Ctrl+Alt on Windows and Linux.
    return platform.os !== "mac" && combo.ctrl && combo.alt && !combo.meta && printable
  }
  if (combo.alt) {
    // Option types characters on Mac; Alt with a letter does not type elsewhere.
    return platform.os === "mac" && printable
  }
  if (/^F\d+$/.test(combo.key)) return false
  // Plain or shifted keys: characters type, and named keys (arrows, Enter,
  // Escape, Backspace, Tab) edit or move within the field.
  return true
}

const allowedWhileTyping = (command: Command, combo: KeyCombo, platform: Platform, event: KeyEventLike): boolean => {
  switch (command.whileTyping) {
    case "always":
      return true
    case "never":
      return false
    default:
      return !canBeTyping(combo, platform, event)
  }
}

export type KeyboardDispatcherOptions = {
  readonly registry: CommandRegistry
  readonly platform: Platform
  /** Decides whether the event target is a text field. Defaults to `isTextInputTarget`. */
  readonly isTextInput?: (target: unknown) => boolean
  /**
   * Called for a character typed outside any text field when no command
   * matched and no modal layer is open: the Mac app focuses the composer so
   * typing anywhere starts a message.
   */
  readonly onTypeToFocus?: (event: KeyEventLike) => void
}

export class KeyboardDispatcher {
  readonly registry: CommandRegistry
  readonly platform: Platform
  readonly #isTextInput: (target: unknown) => boolean
  readonly #onTypeToFocus: ((event: KeyEventLike) => void) | undefined
  readonly #focusScopes = signal<readonly ScopeId[]>([])
  readonly #layers = signal<readonly Layer[]>([])

  /** Scopes in resolution order, ending with `global` unless a modal layer is open. */
  readonly activeScopes: ReadSignal<readonly ScopeId[]>
  /** Whether a modal layer is open. */
  readonly hasModalLayer: ReadSignal<boolean>

  constructor(options: KeyboardDispatcherOptions) {
    this.registry = options.registry
    this.platform = options.platform
    this.#isTextInput = options.isTextInput ?? isTextInputTarget
    this.#onTypeToFocus = options.onTypeToFocus
    this.activeScopes = computed(() => {
      const scopes: ScopeId[] = []
      const layers = this.#layers.get()
      for (let i = layers.length - 1; i >= 0; i--) {
        const layer = layers[i] as Layer
        scopes.push(layer.scope)
        if (layer.modal) return scopes
      }
      for (const scope of this.#focusScopes.get()) if (!scopes.includes(scope)) scopes.push(scope)
      if (!scopes.includes("global")) scopes.push("global")
      return scopes
    })
    this.hasModalLayer = computed(() => this.#layers.get().some((layer) => layer.modal))
  }

  /** Set the scopes of the focused region, innermost first. Called on focus changes. */
  setFocusScopes(scopes: readonly ScopeId[]): void {
    this.#focusScopes.set([...scopes])
  }

  /** Open a layer (a menu, a dialog). Returns a function that closes it. */
  pushLayer(scope: ScopeId, options: { modal?: boolean } = {}): () => void {
    const layer: Layer = { scope, modal: options.modal ?? false }
    this.#layers.set([...this.#layers.peek(), layer])
    return () => {
      this.#layers.set(this.#layers.peek().filter((l) => l !== layer))
    }
  }

  /** Resolve without running. Pure apart from reading signals. */
  resolve(event: KeyEventLike): Resolution {
    if (isComposingEvent(event)) return { kind: "none", reason: "composing" }
    const combo = eventCombo(event)
    if (!combo) return { kind: "none", reason: "modifierOnly" }
    const typing = this.#isTextInput(event.target)
    const bindings = this.registry.bindings(this.platform).get(comboId(combo)) ?? []
    let sawDisabled = false
    let sawTyping = false
    const scopes = this.activeScopes.peek()
    for (const scope of scopes) {
      for (const binding of bindings as readonly Binding[]) {
        const command = binding.command
        if (command.scope !== scope) continue
        if (typing && !allowedWhileTyping(command, combo, this.platform, event)) {
          sawTyping = true
          continue
        }
        if (!command.enabled.peek()) {
          sawDisabled = true
          continue
        }
        if (event.repeat && !command.repeat) return { kind: "swallow", command }
        return { kind: "command", command, combo }
      }
    }
    if (
      !typing &&
      bindings.length === 0 &&
      !combo.ctrl &&
      !combo.meta &&
      !combo.alt &&
      isPrintableKey(combo.key) &&
      combo.key !== "Space" &&
      !this.hasModalLayer.peek()
    ) {
      return { kind: "typeToFocus" }
    }
    return { kind: "none", reason: sawTyping ? "typing" : sawDisabled ? "disabled" : "unbound" }
  }

  /**
   * Handle a keydown: resolve, run, and prevent the browser default when a
   * command took the key. Ignores events another handler already prevented.
   */
  handleKeyDown(event: KeyEventLike): Resolution {
    if (event.defaultPrevented) return { kind: "none", reason: "unbound" }
    const resolution = this.resolve(event)
    switch (resolution.kind) {
      case "command":
        event.preventDefault?.()
        resolution.command.run({ source: "keyboard", event })
        break
      case "swallow":
        event.preventDefault?.()
        break
      case "typeToFocus":
        // Not prevented: the character goes to whatever takes focus.
        this.#onTypeToFocus?.(event)
        break
      case "none":
        break
    }
    return resolution
  }
}
