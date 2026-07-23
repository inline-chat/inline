import { InlineClientProvider } from "@inline/client/react"
import type { UserID } from "@inline/ids"
import {
  useEffect,
  useLayoutEffect,
  useRef,
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
  replaceUnresponsiveInlineRuntimeCore,
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
  const [binding, setBinding] = useState<InlineRuntimeCoreBinding>(() =>
    getInlineRuntimeCoreBinding(userId),
  )
  const replacementAttempted = useRef(false)
  const { core } = binding
  const state = useSyncExternalStore(
    core.subscribe,
    core.getSnapshot,
    core.getSnapshot,
  )

  useLayoutEffect(() => {
    return binding.retain()
  }, [binding])

  useEffect(() => {
    void core.start().catch(() => {
      // The core publishes the actionable failure through its snapshot.
    })
  }, [core])

  const replaceableBootFailure =
    state.blockingFailure != null &&
    core.canReplaceUnresponsiveBootOwner()

  useEffect(() => {
    if (!replaceableBootFailure || replacementAttempted.current) return
    replacementAttempted.current = true
    const replacement = replaceUnresponsiveInlineRuntimeCore(core)
    if (!replacement) return
    setBinding({
      core: replacement,
      retain: () => getInlineRuntimeCoreBinding(userId).retain(),
    })
  }, [core, replaceableBootFailure, userId])

  if (
    state.blockingFailure?.recoveryAction === "reload" &&
    !replaceableBootFailure
  ) {
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
