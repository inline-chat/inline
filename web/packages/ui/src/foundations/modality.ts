/**
 * Input modality: was the last interaction a keyboard, a mouse or pen, or a
 * touch? Browsers already apply `:focus-visible` for focus rings; controllers
 * use this for behavior: a tooltip opens on keyboard focus but not on touch
 * focus, and a menu opened from the keyboard highlights its first item.
 */

import { type ReadSignal, type Signal, signal } from "@inline/reactive"
import { type Dispose, listen } from "./dom"

export type Modality = "keyboard" | "pointer" | "touch"

const modifierKeys = new Set(["Shift", "Control", "Alt", "Meta", "CapsLock", "Fn", "OS"])

export interface ModalityTracker {
  readonly modality: ReadSignal<Modality>
  /** Matches the `:focus-visible` heuristic: show a ring after keyboard input. */
  isKeyboard(): boolean
  dispose(): void
}

export const createModalityTracker = (doc: Document): ModalityTracker => {
  const modality: Signal<Modality> = signal<Modality>("pointer")
  const disposers: Dispose[] = [
    listen(
      doc,
      "keydown",
      (event: KeyboardEvent) => {
        // Command chords (Cmd+Tab and friends) do not mean the user is driving with the keyboard.
        if (event.metaKey || event.ctrlKey || event.altKey) return
        if (modifierKeys.has(event.key)) return
        modality.set("keyboard")
      },
      true,
    ),
    listen(
      doc,
      "pointerdown",
      (event: PointerEvent) => {
        modality.set(event.pointerType === "touch" ? "touch" : "pointer")
      },
      true,
    ),
  ]
  return {
    modality,
    isKeyboard: () => modality.peek() === "keyboard",
    dispose: () => {
      for (const dispose of disposers) dispose()
    },
  }
}

const shared = new WeakMap<Document, { tracker: ModalityTracker; users: number }>()

/** A shared tracker per document, reference counted. Call the returned release when done. */
export const acquireModality = (doc: Document): { tracker: ModalityTracker; release: Dispose } => {
  let entry = shared.get(doc)
  if (!entry) {
    entry = { tracker: createModalityTracker(doc), users: 0 }
    shared.set(doc, entry)
  }
  entry.users++
  let released = false
  const current = entry
  return {
    tracker: current.tracker,
    release: () => {
      if (released) return
      released = true
      current.users--
      if (current.users === 0) {
        current.tracker.dispose()
        shared.delete(doc)
      }
    },
  }
}
