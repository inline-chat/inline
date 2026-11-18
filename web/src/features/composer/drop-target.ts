/**
 * Files dragged over a chat: the chat pane hands its root element to this
 * controller (`useElement`), mounts `DropOverlay` inside it, and files
 * dropped anywhere on the pane go to the chat's attachments. Framework-free.
 *
 * - Only drags that carry files activate it; text and in-app drags are left
 *   alone (the composer takes dropped text itself).
 * - `dragenter` and `dragleave` fire for every child crossed, so a depth
 *   counter says when the drag really left the pane.
 * - A drop the composer surface already handled (its binding takes files
 *   dropped on it and calls `preventDefault`) is not added twice.
 */

import { type ReadSignal, signal } from "@inline/reactive"

export type DropTargetOptions = {
  /** Files dropped on the pane. */
  readonly onFiles: (files: readonly File[]) => void
  /** False while the pane cannot take files (editing a message, no chat). Default always. */
  readonly enabled?: () => boolean
}

/** The parts of a drag event the controller reads. */
type DragFacts = Pick<DragEvent, "dataTransfer" | "defaultPrevented" | "preventDefault">

const carriesFiles = (event: DragFacts): boolean => {
  const types = event.dataTransfer?.types
  if (!types) return false
  for (const type of Array.from(types)) if (type === "Files") return true
  return false
}

export class DropTarget {
  readonly #active = signal(false)
  readonly #onFiles: (files: readonly File[]) => void
  readonly #enabled: () => boolean
  #depth = 0

  constructor(options: DropTargetOptions) {
    this.#onFiles = options.onFiles
    this.#enabled = options.enabled ?? (() => true)
  }

  /** True while files are dragged over the pane: show the overlay. */
  get active(): ReadSignal<boolean> {
    return this.#active
  }

  /** The chat pane's root element. */
  readonly attach = (element: HTMLElement): (() => void) => {
    const view = element.ownerDocument.defaultView
    const reset = () => {
      this.#depth = 0
      this.#active.set(false)
    }
    const onEnter = (event: DragEvent) => {
      if (!carriesFiles(event) || !this.#enabled()) return
      event.preventDefault()
      this.#depth += 1
      this.#active.set(true)
    }
    const onOver = (event: DragEvent) => {
      if (!carriesFiles(event) || !this.#enabled()) return
      event.preventDefault()
      if (event.dataTransfer) event.dataTransfer.dropEffect = "copy"
      if (!this.#active.peek()) this.#active.set(true)
    }
    const onLeave = (event: DragEvent) => {
      if (!carriesFiles(event)) return
      this.#depth = Math.max(0, this.#depth - 1)
      if (this.#depth === 0) this.#active.set(false)
    }
    const onDrop = (event: DragEvent) => {
      reset()
      if (!carriesFiles(event) || event.defaultPrevented || !this.#enabled()) return
      event.preventDefault()
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length > 0) this.#onFiles(files)
    }
    element.addEventListener("dragenter", onEnter)
    element.addEventListener("dragover", onOver)
    element.addEventListener("dragleave", onLeave)
    element.addEventListener("drop", onDrop)
    // A drag cancelled outside the window, or the window losing focus mid-drag.
    view?.addEventListener("dragend", reset)
    view?.addEventListener("blur", reset)
    return () => {
      element.removeEventListener("dragenter", onEnter)
      element.removeEventListener("dragover", onOver)
      element.removeEventListener("dragleave", onLeave)
      element.removeEventListener("drop", onDrop)
      view?.removeEventListener("dragend", reset)
      view?.removeEventListener("blur", reset)
      reset()
    }
  }
}
