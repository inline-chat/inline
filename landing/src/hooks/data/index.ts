import {
  DbObjectKind,
  type Dialog,
  type Space,
  useCurrentUserId,
  useObject,
  useObjectRef,
  useQueryObjects,
  type User,
} from "@inline/client"
import { compareInlineIds } from "@inline/ids"
import { useMemo } from "react"

/** Get the current user from the database. */
export const useCurrentUser = (): User | undefined => {
  const currentUserId = useCurrentUserId()
  const currentUserRef = useObjectRef(
    DbObjectKind.User,
    currentUserId ?? undefined,
  )
  return useObject(currentUserRef)
}

/** Get dialogs from the database, sorted by pinned then id descending. */
export const useDialogs = (): Dialog[] => {
  const dialogs = useQueryObjects(DbObjectKind.Dialog)
  return useMemo(() => {
    return [...dialogs].sort((a, b) => {
      const pinnedA = a.pinned ? 1 : 0
      const pinnedB = b.pinned ? 1 : 0
      if (pinnedA !== pinnedB) return pinnedB - pinnedA
      return compareInlineIds(b.id, a.id)
    })
  }, [dialogs])
}

export const useHomeDialogs = (): Dialog[] => {
  const dialogs = useQueryObjects(DbObjectKind.Dialog, (object) => {
    return !object.archived && object.peerUserId !== undefined
  })

  return useMemo(() => {
    return [...dialogs].sort((a, b) => {
      const pinnedA = a.pinned ? 1 : 0
      const pinnedB = b.pinned ? 1 : 0
      if (pinnedA !== pinnedB) return pinnedB - pinnedA
      return compareInlineIds(b.id, a.id)
    })
  }, [dialogs])
}

export const useSpaces = (): Space[] => {
  const spaces = useQueryObjects(DbObjectKind.Space)
  return useMemo(() => {
    return [...spaces].sort((a, b) => {
      return compareInlineIds(b.id, a.id)
    })
  }, [spaces])
}
