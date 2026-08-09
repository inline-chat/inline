import { InlineClientProvider } from "@inline/client/react"
import type { UserID } from "@inline/ids"
import {
  useLayoutEffect,
  useState,
  useSyncExternalStore,
  type ReactNode,
} from "react"
import { InlineMediaProvider } from "../media/InlineMediaContext"
import { InlineMessageDraftsProvider } from "../drafts/InlineMessageDraftsContext"
import { InlineMessageReferencesProvider } from "../messages/InlineMessageReferencesContext"
import { InlineCoreRecoveryView } from "./InlineCoreRecoveryView"
import { AppBootView } from "~/app/AppBootView"
import {
  getInlineRuntimeCoreBinding,
  type InlineRuntimeCoreBinding,
} from "./InlineRuntimeCore"
import {
  FullChatProgressiveContext,
  InlineRuntimeStateContext,
} from "./InlineRuntimeContext"

export function InlineRuntime({
  userId,
  children,
}: {
  userId: UserID
  children: ReactNode
}) {
  return (
    <InlineRuntimeForAccount key={userId} userId={userId}>
      {children}
    </InlineRuntimeForAccount>
  )
}

function InlineRuntimeForAccount({
  userId,
  children,
}: {
  userId: UserID
  children: ReactNode
}) {
  const [binding] = useState<InlineRuntimeCoreBinding>(() =>
    getInlineRuntimeCoreBinding(userId),
  )
  const { core } = binding
  const state = useSyncExternalStore(
    core.subscribe,
    core.getSnapshot,
    core.getSnapshot,
  )

  useLayoutEffect(() => {
    return binding.retain()
  }, [binding])

  if (state.blockingFailure?.recoveryAction === "reload") {
    return (
      <InlineCoreRecoveryView
        failureCode={state.blockingFailure.code}
        failureMessage={state.blockingFailure.message}
      />
    )
  }

  if (!state.cacheReady) return <AppBootView />

  return (
    <InlineClientProvider value={core.client}>
      <FullChatProgressiveContext.Provider value={core.fullChatProgressive}>
        <InlineMessageDraftsProvider drafts={core.messageDrafts}>
          <InlineMessageReferencesProvider references={core.messageReferences}>
            <InlineMediaProvider repository={core.mediaRepository}>
              <InlineRuntimeStateContext.Provider value={state}>{children}</InlineRuntimeStateContext.Provider>
            </InlineMediaProvider>
          </InlineMessageReferencesProvider>
        </InlineMessageDraftsProvider>
      </FullChatProgressiveContext.Provider>
    </InlineClientProvider>
  )
}
