import "../../styles/base.css"
import {
  mountMessageListBrowserHarness,
  type MessageListBrowserHarness,
} from "./MessageListBrowserHarness"

declare global {
  interface Window {
    inlineMessageListHarness: {
      mount: (
        options?: { resetScrollState?: boolean },
      ) => Promise<MessageListBrowserHarness>
    }
    inlineMessageListHarnessReady: Promise<MessageListBrowserHarness>
  }
}

const root = document.querySelector<HTMLElement>(
  "#message-list-harness-root",
)
if (!root) throw new Error("Inline message-list harness root is missing")

// StyleX's development virtual stylesheet is populated as modules transform.
// This harness is itself the first cold import of MessageListView, so fetch a
// fresh stylesheet only after that static module graph has evaluated.
const stylexStylesheet = document.createElement("link")
stylexStylesheet.rel = "stylesheet"
const harnessModuleUrl = new URL(import.meta.url)
stylexStylesheet.href = `${harnessModuleUrl.origin}/virtual:stylex.css?harness=${Date.now()}`
await new Promise<void>((resolve, reject) => {
  stylexStylesheet.addEventListener("load", () => resolve(), {
    once: true,
  })
  stylexStylesheet.addEventListener(
    "error",
    () => reject(new Error("Could not load the StyleX harness stylesheet")),
    { once: true },
  )
  document.head.append(stylexStylesheet)
})

window.inlineMessageListHarness = {
  mount: (options) =>
    mountMessageListBrowserHarness(root, options),
}
window.inlineMessageListHarnessReady =
  window.inlineMessageListHarness.mount()
