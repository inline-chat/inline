/**
 * The chat info pane: header, then the kit's Tabs: Participants (threads),
 * Media, Files, Voice, Links (`ChatMediaTab.tsx`) and Settings. Renders a
 * `ChatInfoModel`; every list row reads only its own computed, so one member
 * changing renders one row.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { Avatar, Badge, Button, ContextMenuArea, Dialog, SegmentedControl, Switch, Tabs } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { radius } from "@inline/ui/tokens/radius.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import type { RowKey } from "@inline/core-protocol"
import * as stylex from "@stylexjs/stylex"
import { memo, type ReactNode } from "react"
import type { UserID } from "@inline/ids"
import type { AddPeopleModel } from "./add-people"
import { NOTIFICATION_CHOICES, type ChatInfoModel, type ControlId, type NotificationChoice } from "./chat-info-model"
import type { ChatMediaTabId } from "./chat-media-model"
import { ChatMediaTab } from "./ChatMediaTab"

export function ChatInfoPane(props: { model: ChatInfoModel }) {
  const tabs = useSignal(props.model.tabs)
  return (
    <section aria-label="Chat info" {...stylex.props(styles.pane)}>
      <Header model={props.model} />
      {tabs.length > 1 ? (
        <Tabs
          controller={props.model.tabsController}
          tabs={tabs}
          renderPanel={(id) =>
            id === "participants" ? (
              <ParticipantsPanel model={props.model} />
            ) : id === "settings" ? (
              <SettingsPanel model={props.model} />
            ) : (
              <ChatMediaTab model={props.model} tab={id as ChatMediaTabId} />
            )
          }
        />
      ) : (
        <SettingsPanel model={props.model} />
      )}
    </section>
  )
}

function Header(props: { model: ChatInfoModel }) {
  const header = useSignal(props.model.header)
  const avatar = header.avatar
  return (
    <header {...stylex.props(styles.header)}>
      {avatar.kind === "chat" && avatar.emoji ? (
        <span aria-hidden="true" {...stylex.props(styles.emojiAvatar)}>
          {avatar.emoji}
        </span>
      ) : (
        <span aria-hidden="true" {...stylex.props(styles.avatarWrap)}>
          <Avatar name={header.title} seed={avatar.seed} size="large" {...(avatar.kind === "user" && avatar.photoUrl ? { src: avatar.photoUrl } : {})} />
        </span>
      )}
      <h2 dir="auto" {...stylex.props(styles.title)}>
        {header.title}
      </h2>
      <p {...stylex.props(styles.subtitle)}>
        {header.kindLabel}
        {header.countText ? ` · ${header.countText}` : null}
      </p>
      <ChatIdRow model={props.model} chatId={header.chatIdText} />
    </header>
  )
}

function ChatIdRow(props: { model: ChatInfoModel; chatId: string }) {
  const copyState = useSignal(props.model.copyState)
  return (
    <div {...stylex.props(styles.idRow)}>
      <span {...stylex.props(styles.idLabel)}>Chat ID</span>
      <code {...stylex.props(styles.idValue)}>{props.chatId}</code>
      {props.model.canCopy ? (
        <Button size="small" aria-label="Copy chat ID" onClick={() => props.model.copyChatId()}>
          Copy
        </Button>
      ) : null}
      <span role="status" {...stylex.props(styles.idStatus)}>
        {copyState === "copied" ? "Copied" : copyState === "failed" ? "Couldn't copy" : ""}
      </span>
    </div>
  )
}

// MARK: Participants

function ParticipantsPanel(props: { model: ChatInfoModel }) {
  const participants = props.model.participants
  const ids = useSignal(props.model.members.ids)
  const status = useSignal(participants.status)
  const empty = useSignal(participants.showEmpty)
  const canAdd = useSignal(props.model.members.canAdd)
  const listRef = useElement(props.model.list.root)
  return (
    <div {...stylex.props(styles.panel)}>
      <div {...stylex.props(styles.panelBar)}>
        <p role="status" {...stylex.props(styles.listStatus)}>
          {status === "loading" ? "Updating…" : status === "failed" ? "Couldn't refresh the list. Showing what's on this device." : ""}
        </p>
        {canAdd ? (
          <Button size="small" onClick={() => props.model.addPeople.open()}>
            Add People
          </Button>
        ) : null}
      </div>
      <AddPeople model={props.model.addPeople} />
      {empty && ids.length === 0 ? (
        <p {...stylex.props(styles.note)}>No access grants found in this chat.</p>
      ) : (
        <ContextMenuArea controller={props.model.participantMenu}>
          <div ref={listRef} {...stylex.props(styles.list, styles.focusRing)}>
            {ids.map((key) => (
              <ParticipantRow key={key} model={props.model} id={key} />
            ))}
          </div>
        </ContextMenuArea>
      )}
      <MemberActionLine model={props.model} />
      <RemoveDialog model={props.model} />
    </div>
  )
}

function AddPeople(props: { model: AddPeopleModel }) {
  const open = useSignal(props.model.isOpen)
  if (!open) return null
  return <AddPeopleBody model={props.model} />
}

function AddPeopleBody(props: { model: AddPeopleModel }) {
  const picker = props.model
  const query = useSignal(picker.query)
  const matches = useSignal(picker.matches)
  const picked = useSignal(picker.pickedPeople)
  const loading = useSignal(picker.loading)
  const active = useSignal(picker.listbox.activeId)
  const listRef = useElement(picker.listbox.passiveRoot)
  return (
    <div role="group" aria-label="Add people" {...stylex.props(styles.addPanel)}>
      {picked.length > 0 ? (
        <ul aria-label="Picked" {...stylex.props(styles.chips)}>
          {picked.map((person) => (
            <li key={person.userId} {...stylex.props(styles.chip)}>
              <span dir="auto">{person.name}</span>
              <button type="button" aria-label={`Remove ${person.name}`} onClick={() => picker.toggle(person.userId)} {...stylex.props(styles.chipRemove, styles.focusRing)}>
                ×
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      <input
        ref={focusOnMount}
        type="search"
        dir="auto"
        aria-label="Search people"
        placeholder="Search people"
        role="combobox"
        aria-expanded={matches.length > 0}
        aria-controls={picker.listbox.id}
        aria-activedescendant={active === null ? undefined : picker.listbox.optionDomId(active)}
        value={query}
        onInput={(event) => picker.setQuery(event.currentTarget.value)}
        onChange={() => {}}
        onKeyDown={(event) => {
          if (picker.handleKey(event.key)) event.preventDefault()
        }}
        {...stylex.props(styles.search, styles.focusRing)}
      />
      <div ref={listRef} aria-label="People" aria-multiselectable="true" {...stylex.props(styles.addList)}>
        {matches.map((person) => (
          <AddPeopleRow key={person.userId} model={picker} userId={person.userId} name={person.name} username={person.username} avatar={person.avatar} />
        ))}
      </div>
      {matches.length === 0 ? <p {...stylex.props(styles.listStatus)}>{loading ? "Loading people…" : query ? "No one matches." : "Everyone here is already in this chat."}</p> : null}
      <div {...stylex.props(styles.addActions)}>
        <Button size="small" onClick={() => picker.close()}>
          Cancel
        </Button>
        <Button size="small" variant="primary" disabled={picked.length === 0} onClick={() => picker.submit()}>
          Add
        </Button>
      </div>
    </div>
  )
}

/** Focus the search field when the picker opens, without scrolling. */
const focusOnMount = (element: HTMLInputElement | null) => {
  element?.focus({ preventScroll: true })
}

function AddPeopleRow(props: { model: AddPeopleModel; userId: UserID; name: string; username: string | undefined; avatar: { name: string; seed: string; src?: string } }) {
  const ref = useElement(props.model.listbox.option(props.userId))
  const active = useSignal(props.model.listbox.isActive(props.userId))
  const picked = useSignal(props.model.isPicked(props.userId))
  return (
    <div ref={ref} aria-selected={picked} {...stylex.props(styles.row, active && styles.rowActive)}>
      <span aria-hidden="true" {...stylex.props(styles.rowAvatar)}>
        <Avatar name={props.avatar.name} seed={props.avatar.seed} size="regular" {...(props.avatar.src ? { src: props.avatar.src } : {})} />
      </span>
      <span {...stylex.props(styles.rowText)}>
        <span dir="auto" {...stylex.props(styles.rowTitle)}>
          {props.name}
        </span>
        {props.username ? (
          <span dir="auto" {...stylex.props(styles.rowSubtitle)}>
            @{props.username}
          </span>
        ) : null}
      </span>
      {picked ? <span aria-hidden="true" {...stylex.props(styles.check)}>✓</span> : null}
    </div>
  )
}

function MemberActionLine(props: { model: ChatInfoModel }) {
  const state = useSignal(props.model.members.state)
  if (state.kind === "idle") return <p role="status" {...stylex.props(styles.message)} />
  const tone = state.kind === "failed" ? styles.messageError : state.kind === "uncertain" ? styles.messageWarning : null
  const text = state.kind === "pending" || state.kind === "done" ? state.text : `${state.notice.title}. ${state.notice.text}`
  return (
    <p role={state.kind === "failed" ? "alert" : "status"} {...stylex.props(styles.message, tone)}>
      {text}{" "}
      {state.kind === "pending" ? null : (
        <button type="button" onClick={() => props.model.members.dismiss()} {...stylex.props(styles.dismiss, styles.focusRing)}>
          Dismiss
        </button>
      )}
    </p>
  )
}

function RemoveDialog(props: { model: ChatInfoModel }) {
  const question = useSignal(props.model.members.question)
  return (
    <Dialog
      controller={props.model.removeDialog}
      title={question?.title ?? "Remove participant?"}
      {...(question ? { description: question.text } : {})}
      closeButton={false}
      footer={
        <>
          <Button onClick={() => props.model.members.cancelRemove()}>Cancel</Button>
          <Button variant="destructive" onClick={() => props.model.members.confirmRemove()}>
            {question?.confirm ?? "Remove"}
          </Button>
        </>
      }
    />
  )
}

const ParticipantRow = memo(function ParticipantRow(props: { model: ChatInfoModel; id: RowKey }) {
  const item = useSignal(props.model.participants.member(props.id))
  const active = useSignal(props.model.list.isActive(props.id))
  const ref = useElement(props.model.list.option(props.id))
  return (
    <div ref={ref} data-participant={props.id} {...stylex.props(styles.row, active && styles.rowActive)}>
      <span aria-hidden="true" {...stylex.props(styles.rowAvatar)}>
        {item ? <Avatar name={item.avatar.name} seed={item.avatar.seed} size="regular" {...(item.avatar.src ? { src: item.avatar.src } : {})} /> : null}
      </span>
      <span {...stylex.props(styles.rowText)}>
        <span {...stylex.props(styles.rowTitleLine)}>
          <span dir="auto" {...stylex.props(styles.rowTitle)}>
            {item?.name ?? ""}
          </span>
          {item?.kind === "user" && item.isViewer ? <span {...stylex.props(styles.you)}>You</span> : null}
          {item?.kind === "user" && item.role ? <Badge>{item.role === "owner" ? "Owner" : "Admin"}</Badge> : null}
          {item?.kind === "user" && item.restricted ? <Badge>Restricted</Badge> : null}
          {item?.kind === "user" && item.bot ? <Badge tone="warning">Bot</Badge> : null}
        </span>
        {item?.kind === "group" ? (
          <span dir="auto" {...stylex.props(styles.rowSubtitle)}>
            {item.subtitle}
          </span>
        ) : item?.username ? (
          <span dir="auto" {...stylex.props(styles.rowSubtitle)}>
            @{item.username}
          </span>
        ) : null}
      </span>
    </div>
  )
})

// MARK: Settings

function SettingsPanel(props: { model: ChatInfoModel }) {
  const settings = useSignal(props.model.settings)
  return (
    <div {...stylex.props(styles.panel, styles.settings)}>
      <SettingRow model={props.model} control="notifications" label="Notifications">
        <SegmentedControl<NotificationChoice>
          label="Notifications"
          options={NOTIFICATION_CHOICES}
          value={settings.notifications}
          onChange={(value) => props.model.setNotifications(value)}
        />
      </SettingRow>
      {settings.isThread ? (
        <SettingRow
          model={props.model}
          control="follow"
          description={
            settings.following
              ? "New messages bring this thread to the sidebar."
              : "Mentions and replies still bring this thread to the sidebar."
          }
        >
          <Switch controller={props.model.followSwitch} label="Follow thread" />
        </SettingRow>
      ) : null}
      <SettingRow model={props.model} control="pin">
        <Switch controller={props.model.pinSwitch} label="Pin in sidebar" />
      </SettingRow>
      <SettingRow model={props.model} control="archive">
        <Switch controller={props.model.archiveSwitch} label="Archived" />
      </SettingRow>
      <SettingRow model={props.model} control="unread">
        <Button disabled={!settings.available || settings.unread} onClick={() => props.model.markUnread()}>
          Mark as Unread
        </Button>
      </SettingRow>
    </div>
  )
}

function SettingRow(props: { model: ChatInfoModel; control: ControlId; label?: string; description?: string; children: ReactNode }) {
  return (
    <div {...stylex.props(styles.settingRow)}>
      {props.label ? <span {...stylex.props(styles.settingLabel)}>{props.label}</span> : null}
      <div {...stylex.props(styles.settingControl)}>{props.children}</div>
      {props.description ? <p {...stylex.props(styles.settingDescription)}>{props.description}</p> : null}
      <ControlMessage model={props.model} control={props.control} />
    </div>
  )
}

function ControlMessage(props: { model: ChatInfoModel; control: ControlId }) {
  const state = useSignal(props.model.control(props.control))
  if (state.kind === "idle" || state.kind === "pending") return <p role="status" {...stylex.props(styles.message)} />
  const tone = state.kind === "failed" ? styles.messageError : state.kind === "uncertain" ? styles.messageWarning : null
  const text = state.kind === "waiting" ? state.text : `${state.notice.title}. ${state.notice.text}`
  return (
    <p role={state.kind === "failed" ? "alert" : "status"} {...stylex.props(styles.message, tone)}>
      {text}{" "}
      <button type="button" onClick={() => props.model.dismiss(props.control)} {...stylex.props(styles.dismiss, styles.focusRing)}>
        Dismiss
      </button>
    </p>
  )
}

const styles = stylex.create({
  pane: {
    display: "flex",
    flexDirection: "column",
    gap: space.xxxl,
    boxSizing: "border-box",
    inlineSize: "100%",
    maxInlineSize: "560px",
    marginInline: "auto",
    paddingBlock: space.xxxl,
    paddingInline: space.xl,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
    lineHeight: font.lineHeightBody,
  },
  header: { display: "flex", flexDirection: "column", alignItems: "center", gap: space.sm, textAlign: "center" },
  avatarWrap: { display: "inline-flex" },
  emojiAvatar: {
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    inlineSize: "80px",
    blockSize: "80px",
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
    fontSize: "44px",
    lineHeight: 1,
  },
  title: {
    margin: 0,
    fontSize: font.sizeTitle3,
    fontWeight: font.weightSemibold,
    maxInlineSize: "100%",
    overflowWrap: "anywhere",
  },
  subtitle: { margin: 0, color: color.secondaryLabel, fontSize: font.sizeCallout },
  idRow: { display: "flex", alignItems: "center", gap: space.md, flexWrap: "wrap", justifyContent: "center", marginBlockStart: space.xs },
  idLabel: { color: color.secondaryLabel, fontSize: font.sizeCallout },
  idValue: { fontFamily: font.familyMono, color: color.secondaryLabel, userSelect: "all" },
  idStatus: { minInlineSize: "6em", textAlign: "start", color: color.secondaryLabel, fontSize: font.sizeCallout },
  panel: { display: "flex", flexDirection: "column", gap: space.sm, minInlineSize: 0 },
  panelBar: { display: "flex", alignItems: "center", justifyContent: "space-between", gap: space.md },
  addPanel: {
    display: "flex",
    flexDirection: "column",
    gap: space.sm,
    padding: space.md,
    borderRadius: radius.content,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.separator,
    backgroundColor: color.textBackground,
  },
  chips: { display: "flex", flexWrap: "wrap", gap: space.xs, margin: 0, padding: 0, listStyle: "none" },
  chip: {
    display: "inline-flex",
    alignItems: "center",
    gap: space.xs,
    paddingInlineStart: space.sm,
    borderRadius: radius.pill,
    backgroundColor: color.controlTrack,
    fontSize: font.sizeCallout,
  },
  chipRemove: { borderWidth: 0, backgroundColor: "transparent", color: color.secondaryLabel, cursor: "pointer", fontSize: font.sizeBody },
  search: {
    boxSizing: "border-box",
    inlineSize: "100%",
    paddingBlock: space.sm,
    paddingInline: space.md,
    borderRadius: radius.control,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.separator,
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: "inherit",
    fontSize: font.sizeBody,
  },
  addList: { display: "flex", flexDirection: "column", maxBlockSize: "280px", overflowY: "auto", outline: "none" },
  addActions: { display: "flex", justifyContent: "flex-end", gap: space.sm },
  check: { color: color.accent, flexShrink: 0 },
  note: { margin: 0, paddingBlock: space.huge, textAlign: "center", color: color.secondaryLabel },
  listStatus: { margin: 0, minBlockSize: "1.2em", color: color.secondaryLabel, fontSize: font.sizeCallout },
  list: {
    display: "flex",
    flexDirection: "column",
    padding: space.xs,
    borderRadius: radius.content,
    borderWidth: space.hairline,
    borderStyle: "solid",
    borderColor: color.separator,
    backgroundColor: color.textBackground,
  },
  focusRing: {
    outline: { default: "none", ":focus-visible": `${size.focusRingWidth} solid ${color.focusRing}` },
    outlineOffset: "1px",
  },
  row: {
    display: "flex",
    alignItems: "center",
    gap: space.lg,
    minBlockSize: "44px",
    paddingInline: space.md,
    paddingBlock: space.sm,
    borderRadius: radius.menuItem,
    cursor: "default",
    userSelect: "none",
    // Long lists: rows off screen skip layout and paint.
    contentVisibility: "auto",
    containIntrinsicSize: "auto 44px",
    backgroundColor: { default: "transparent", ":hover": color.controlHover },
  },
  rowActive: {
    backgroundColor: color.unemphasizedSelectedContentBackground,
  },
  rowAvatar: { display: "inline-flex", flexShrink: 0, inlineSize: size.avatar, blockSize: size.avatar },
  rowText: { display: "flex", flexDirection: "column", minInlineSize: 0, flexGrow: 1 },
  rowTitleLine: { display: "flex", alignItems: "center", gap: space.sm, minInlineSize: 0 },
  rowTitle: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minInlineSize: 0 },
  rowSubtitle: {
    color: color.secondaryLabel,
    fontSize: font.sizeCallout,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  you: { color: color.secondaryLabel, fontSize: font.sizeCallout, fontWeight: font.weightSemibold, flexShrink: 0 },
  settings: { gap: space.xl },
  settingRow: { display: "flex", flexDirection: "column", alignItems: "flex-start", gap: space.xs },
  settingLabel: { fontWeight: font.weightSemibold },
  settingControl: { display: "flex", alignItems: "center", gap: space.md },
  settingDescription: { margin: 0, color: color.secondaryLabel, fontSize: font.sizeCallout },
  message: { margin: 0, fontSize: font.sizeCallout, color: color.secondaryLabel, minBlockSize: 0 },
  messageError: { color: color.red },
  messageWarning: { color: color.orange },
  dismiss: {
    padding: 0,
    borderWidth: 0,
    backgroundColor: "transparent",
    color: color.link,
    fontFamily: "inherit",
    fontSize: "inherit",
    cursor: "pointer",
    textDecoration: "underline",
  },
})
