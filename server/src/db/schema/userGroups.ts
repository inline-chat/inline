import { creationDate } from "@in/server/db/schema/common"
import { chats } from "@in/server/db/schema/chats"
import { spaces } from "@in/server/db/schema/spaces"
import { lower, users } from "@in/server/db/schema/users"
import { relations } from "drizzle-orm/_relations"
import { integer, index, pgTable, serial, text, uniqueIndex, varchar } from "drizzle-orm/pg-core"

export const userGroups = pgTable(
  "user_groups",
  {
    id: serial().primaryKey(),
    spaceId: integer("space_id")
      .notNull()
      .references(() => spaces.id, { onDelete: "cascade" }),
    name: varchar("name", { length: 80 }).notNull(),
    description: text("description"),
    createdBy: integer("created_by")
      .notNull()
      .references(() => users.id),
    date: creationDate,
  },
  (table) => ({
    spaceNameUnique: uniqueIndex("user_groups_space_name_unique").on(table.spaceId, lower(table.name)),
    spaceIndex: index("user_groups_space_id_idx").on(table.spaceId),
    createdByIndex: index("user_groups_created_by_idx").on(table.createdBy),
  }),
)

export const userGroupMembers = pgTable(
  "user_group_members",
  {
    id: serial().primaryKey(),
    groupId: integer("group_id")
      .notNull()
      .references(() => userGroups.id, { onDelete: "cascade" }),
    userId: integer("user_id")
      .notNull()
      .references(() => users.id, { onDelete: "cascade" }),
    date: creationDate,
  },
  (table) => ({
    groupUserUnique: uniqueIndex("user_group_members_group_user_unique").on(table.groupId, table.userId),
    groupIndex: index("user_group_members_group_id_idx").on(table.groupId),
    userIndex: index("user_group_members_user_id_idx").on(table.userId),
  }),
)

export const chatParticipantGroups = pgTable(
  "chat_participant_groups",
  {
    id: serial().primaryKey(),
    chatId: integer("chat_id")
      .notNull()
      .references(() => chats.id, { onDelete: "cascade" }),
    groupId: integer("group_id")
      .notNull()
      .references(() => userGroups.id, { onDelete: "restrict" }),
    date: creationDate,
  },
  (table) => ({
    chatGroupUnique: uniqueIndex("chat_participant_groups_chat_group_unique").on(table.chatId, table.groupId),
    chatIndex: index("chat_participant_groups_chat_id_idx").on(table.chatId),
    groupIndex: index("chat_participant_groups_group_id_idx").on(table.groupId),
  }),
)

export const userGroupsRelations = relations(userGroups, ({ one, many }) => ({
  space: one(spaces, {
    fields: [userGroups.spaceId],
    references: [spaces.id],
  }),
  creator: one(users, {
    fields: [userGroups.createdBy],
    references: [users.id],
  }),
  members: many(userGroupMembers),
  chatGrants: many(chatParticipantGroups),
}))

export const userGroupMembersRelations = relations(userGroupMembers, ({ one }) => ({
  group: one(userGroups, {
    fields: [userGroupMembers.groupId],
    references: [userGroups.id],
  }),
  user: one(users, {
    fields: [userGroupMembers.userId],
    references: [users.id],
  }),
}))

export const chatParticipantGroupsRelations = relations(chatParticipantGroups, ({ one }) => ({
  chat: one(chats, {
    fields: [chatParticipantGroups.chatId],
    references: [chats.id],
  }),
  group: one(userGroups, {
    fields: [chatParticipantGroups.groupId],
    references: [userGroups.id],
  }),
}))

export type DbUserGroup = typeof userGroups.$inferSelect
export type DbNewUserGroup = typeof userGroups.$inferInsert
export type DbUserGroupMember = typeof userGroupMembers.$inferSelect
export type DbNewUserGroupMember = typeof userGroupMembers.$inferInsert
export type DbChatParticipantGroup = typeof chatParticipantGroups.$inferSelect
export type DbNewChatParticipantGroup = typeof chatParticipantGroups.$inferInsert
