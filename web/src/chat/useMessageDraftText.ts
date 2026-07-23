import {
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react"
import type { MessageEntities } from "@inline-chat/protocol/core"
import { messageDraftPeer, type InlinePeerRoute } from "~/inline/data/peer"
import { InlineCoreProtocolError } from "~/inline/core/InlineCoreRendererClient"
import { useInlineMessageDrafts } from "~/inline/drafts/InlineMessageDraftsContext"

const SAVE_DELAY_MS = 300

const isRetiredCoreOwner = (error: unknown) =>
  error instanceof InlineCoreProtocolError &&
  error.code === "owner-failed"

export const useMessageDraftText = (peer: InlinePeerRoute) => {
  const drafts = useInlineMessageDrafts()
  const draftPeer = messageDraftPeer(peer)
  const [text, setTextState] = useState("")
  const [entities, setEntitiesState] = useState<
    MessageEntities | undefined
  >()
  const [revision, setRevision] = useState(0)
  const textRef = useRef("")
  const entitiesRef = useRef<MessageEntities | undefined>(undefined)
  const revisionRef = useRef(0)
  const changed = useRef(false)
  const suppressRestoration = useRef(false)
  const saveTimer = useRef<ReturnType<typeof setTimeout> | undefined>(
    undefined,
  )

  const persist = useCallback(
    (value: string, valueEntities?: MessageEntities) =>
      drafts.update(draftPeer, value, valueEntities).catch((error) => {
        if (!isRetiredCoreOwner(error)) {
          console.error("Could not persist Inline message draft", error)
        }
      }),
    [draftPeer.peerKind, peer.peerId, drafts],
  )

  useEffect(() => {
    let active = true
    // A core-owner replacement changes the drafts service without unmounting
    // the editor. The previous service receives the cleanup flush but may
    // already be retired, so hand the current dirty value to the replacement
    // immediately instead of waiting for another keystroke.
    if (changed.current) {
      void persist(textRef.current, entitiesRef.current)
    }
    void drafts
      .load(draftPeer)
      .then((draft) => {
        if (
          !active ||
          changed.current ||
          suppressRestoration.current
        ) {
          return
        }
        const restored = draft?.text ?? ""
        textRef.current = restored
        entitiesRef.current = draft?.entities
        setTextState(restored)
        setEntitiesState(draft?.entities)
      })
      .catch((error) => {
        if (!isRetiredCoreOwner(error)) {
          console.error("Could not load Inline message draft", error)
        }
      })
    return () => {
      active = false
      if (saveTimer.current) {
        clearTimeout(saveTimer.current)
        saveTimer.current = undefined
        void persist(textRef.current, entitiesRef.current)
      }
    }
  }, [draftPeer.peerKind, peer.peerId, drafts, persist])

  const setContent = useCallback(
    (value: string, valueEntities?: MessageEntities) => {
      changed.current = true
      suppressRestoration.current = false
      textRef.current = value
      entitiesRef.current = valueEntities
      revisionRef.current += 1
      setTextState(value)
      setEntitiesState(valueEntities)
      setRevision(revisionRef.current)
      if (saveTimer.current) clearTimeout(saveTimer.current)
      saveTimer.current = setTimeout(() => {
        saveTimer.current = undefined
        void persist(textRef.current, entitiesRef.current)
      }, SAVE_DELAY_MS)
    },
    [persist],
  )

  const setText = useCallback(
    (value: string) => setContent(value),
    [setContent],
  )

  const clear = useCallback(async () => {
    if (saveTimer.current) clearTimeout(saveTimer.current)
    saveTimer.current = undefined
    changed.current = false
    suppressRestoration.current = true
    textRef.current = ""
    entitiesRef.current = undefined
    revisionRef.current += 1
    setTextState("")
    setEntitiesState(undefined)
    setRevision(revisionRef.current)
    await drafts.clear(draftPeer)
  }, [draftPeer.peerKind, peer.peerId, drafts])

  const clearIfUnchanged = useCallback(
    async (expectedRevision: number) => {
      if (revisionRef.current !== expectedRevision) return false
      await clear()
      return true
    },
    [clear],
  )

  const currentRevision = useCallback(
    () => revisionRef.current,
    [],
  )

  return {
    text,
    entities,
    revision,
    currentRevision,
    setText,
    setContent,
    clear,
    clearIfUnchanged,
  }
}
