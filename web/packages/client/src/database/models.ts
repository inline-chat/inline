/**
 * Models
 *
 * We use plain typescript objects for now. Later we can upgrade to Effect Schema or Zod.
 *
 */

export type DbModel = User | Dialog | Chat | Message

export enum DbObjectKind {
  Dialog = "D",
  Chat = "C",
  User = "U",
  Message = "M",
  Space = "S",
}

export type DbModels = {
  [DbObjectKind.User]: User
  [DbObjectKind.Dialog]: Dialog
  [DbObjectKind.Chat]: Chat
  [DbObjectKind.Message]: Message
  [DbObjectKind.Space]: Space
}

export interface DbModelBase<K extends DbObjectKind> {
  kind: K
  id: number
}

export interface User extends DbModelBase<DbObjectKind.User> {
  kind: DbObjectKind.User
  id: number
  firstName?: string
  lastName?: string
  username?: string
  email?: string
  min?: boolean

  profilePhoto?: {
    fileUniqueId?: string
    /** not filled out */
    photoId?: number
    cdnUrl?: string
  }
}

export interface Dialog extends DbModelBase<DbObjectKind.Dialog> {
  kind: DbObjectKind.Dialog
  // driven from associated chat ID
  id: number
  chatId: number
  peerUserId?: number
  spaceId?: number
  archived?: boolean
  pinned?: boolean
  readMaxId?: number
  unreadCount?: number
  unreadMark?: boolean
}

export interface Chat extends DbModelBase<DbObjectKind.Chat> {
  kind: DbObjectKind.Chat
  id: number
  title?: string
  spaceId?: number
  emoji?: string
  isPublic?: boolean
  lastMsgId?: number
}

export interface Message extends DbModelBase<DbObjectKind.Message> {
  kind: DbObjectKind.Message
  id: number
  randomId?: bigint
  fromId: number
  peerUserId?: number
  chatId: number
  message?: string
  out?: boolean
  date?: number
  mentioned?: boolean
  replyToMsgId?: number
  editDate?: number
  isSticker?: boolean
}

// export interface Photo extends DbModelBase<DbObjectKind.Photo> {
//   kind: DbObjectKind.Photo
//   id: number
//   chatId: number
//   messageId: number
//   photoId: number
//   photo: Photo
// }

export interface Space extends DbModelBase<DbObjectKind.Space> {
  kind: DbObjectKind.Space

  id: number

  // Name of the space
  name: string

  // Whether the current user is the creator of the space
  creator: boolean

  // Date of creation
  date: number
}
