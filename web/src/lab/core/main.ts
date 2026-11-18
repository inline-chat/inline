import type { ChatID, UserID } from "@inline/ids"
import type { CoreResource, IntentResult } from "@inline/core-protocol"
import { effect } from "@inline/reactive"
import { connectAccount } from "../../core/connect"

const USER = "2001" as UserID
const CHAT = "5001" as ChatID

const out = document.getElementById("out")
const input = document.getElementById("draft") as HTMLInputElement | null
const save = document.getElementById("save")

const { core, client } = connectAccount(USER)

const state: Record<string, unknown> = {
  contextId: core.contextId,
  role: core.role,
  results: [] as IntentResult[],
}

const render = () => {
  if (out) out.textContent = JSON.stringify(state, null, 2)
  ;(globalThis as { __coreLab?: unknown }).__coreLab = state
}

core.onRole((role) => {
  state.role = role
  render()
})

// The lab has no server: any token starts the account, which then stays offline.
core.post({ kind: "session", action: "start", session: { userId: USER, token: "core-lab" } })

const coreSub = client.subscribe({ kind: "core" })
const draftSub = client.subscribe({ kind: "draft", chatId: CHAT })
const sidebarSub = client.subscribe({ kind: "sidebar", mode: "inbox" })
const draftRow = client.store.row("draft", CHAT)

let revision = 0
let typed = false

effect(() => {
  const resource = coreSub.resource.get() as CoreResource | undefined
  state.core = resource ?? null
  render()
})

effect(() => {
  const draft = draftRow.get()
  state.draft = draft ?? null
  state.draftListKeys = draftSub.list.get()
  if (draft) {
    revision = Math.max(revision, draft.revision)
    if (input && !typed) input.value = draft.text
  }
  render()
})

effect(() => {
  state.sidebarCount = sidebarSub.list.get().length
  render()
})

input?.addEventListener("input", () => {
  typed = true
})

save?.addEventListener("click", () => {
  revision += 1
  const handle = client.intent({
    kind: "saveDraft",
    chatId: CHAT,
    text: input?.value ?? "",
    revision,
  })
  handle.then(
    (result) => {
      ;(state.results as IntentResult[]).push(result)
      typed = false
      render()
    },
    (error: unknown) => {
      state.error = error instanceof Error ? error.message : String(error)
      render()
    },
  )
})

render()
