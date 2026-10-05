import { useSyncExternalStore } from "react"
import type { Account } from "./core"
import { Boot, Logo } from "./Boot"
import { WorkspaceRouter } from "./Workspace"

export function AccountView({
  account,
  onSignInAgain,
}: {
  account: Account
  onSignInAgain: () => void
}) {
  const snapshot = useSyncExternalStore(account.subscribe, account.getSnapshot, account.getSnapshot)
  if (snapshot.phase === "waiting")
    return (
      <main className="boot">
        <Logo />
        <h1>Inline is open in another tab</h1>
        <p>This tab will open automatically when the other tab closes.</p>
        <p className="muted">For now, Inline can be used in one tab at a time.</p>
      </main>
    )
  if (snapshot.phase === "error")
    return (
      <main className="boot">
        <Logo />
        <h1>Couldn’t open your local messages</h1>
        <p role="alert">{snapshot.error}</p>
        <p>Draft edits that could not be saved may be lost when you reload.</p>
        <button className="primary" onClick={() => window.location.reload()}>
          Reload Inline
        </button>
      </main>
    )
  if (snapshot.phase !== "ready") return <Boot text="Opening your conversations…" />
  return <WorkspaceRouter account={account} onSignInAgain={onSignInAgain} />
}
