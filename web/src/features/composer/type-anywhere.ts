/**
 * Type anywhere to focus the composer: a capture-phase `keydown` listener on
 * the document that moves focus to the active composer before the browser
 * handles a plain character key, so the character lands in the editor.
 * The rule is `shouldFocusForKey` (text.ts). The app shell installs it once
 * and points it at whichever composer is active.
 */

import type { Dispose } from "@inline/reactive"
import { isEditableTarget } from "./dom"
import type { ComposerModel } from "./model"
import { shouldFocusForKey } from "./text"

export const listenTypeAnywhere = (
  doc: Document,
  activeComposer: () => ComposerModel | null,
  onFocused?: (key: string) => void,
): Dispose => {
  const onKeyDown = (event: KeyboardEvent) => {
    const model = activeComposer()
    if (!model) return
    const take = shouldFocusForKey(event, {
      targetIsEditable: isEditableTarget(event.target),
      composerFocused: model.focused.peek(),
    })
    if (take && model.focus()) onFocused?.(event.key)
  }
  doc.addEventListener("keydown", onKeyDown, { capture: true })
  return () => doc.removeEventListener("keydown", onKeyDown, { capture: true })
}
