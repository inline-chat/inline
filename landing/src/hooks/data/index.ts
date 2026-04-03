import {
  db,
  DbObjectKind,
  type Dialog,
  Space,
  useCurrentUserId,
  useObject,
  useQueryObjects,
  User,
} from "@inline/client"
import { useMemo } from "react"

/** Get the current user from the database. */
export const useCurrentUser = (): User | undefined => {
  const currentUserId = useCurrentUserId()
  let currentUser = useObject(currentUserId ? db.ref(DbObjectKind.User, currentUserId) : undefined)
  return currentUser
}

/** Get dialogs from the database, sorted by pinned then id descending. */
export const useDialogs = (): Dialog[] => {
  const dialogs = useQueryObjects(DbObjectKind.Dialog)
  return useMemo(() => {
    return [...dialogs].sort((a, b) => {
      const pinnedA = a.pinned ? 1 : 0
      const pinnedB = b.pinned ? 1 : 0
      if (pinnedA !== pinnedB) return pinnedB - pinnedA
      return b.id - a.id
    })
  }, [dialogs])
}

export const useHomeDialogs = (): Dialog[] => {
  const dialogs = useQueryObjects(DbObjectKind.Dialog, (object) => {
    return !object.archived && typeof object.peerUserId === "number"
  })

  return useMemo(() => {
    return [...dialogs].sort((a, b) => {
      const pinnedA = a.pinned ? 1 : 0
      const pinnedB = b.pinned ? 1 : 0
      if (pinnedA !== pinnedB) return pinnedB - pinnedA
      return b.id - a.id
    })
  }, [dialogs])
}

export const useSpaces = (): Space[] => {
  const spaces = useQueryObjects(DbObjectKind.Space)
  return useMemo(() => {
    return [...spaces].sort((a, b) => {
      return b.id - a.id
    })
  }, [spaces])
}
