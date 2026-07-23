import { DbObjectKind, type User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { useInlineObject } from "~/inline/data/react"
import { useInlineMediaUrl } from "~/inline/media/InlineMediaContext"
import { UserAvatar } from "~/ui/Avatar"
import type { ChatMessageAttachmentPresentation } from "./MessageContent"

function AttachmentLink({
  url,
  label,
  className,
  children,
}: {
  url?: string
  label: string
  className: string
  children: ReactNode
}) {
  return url ? (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={label}
      className={className}
    >
      {children}
    </a>
  ) : (
    <span className={className}>{children}</span>
  )
}

function URLPreviewAttachmentView({
  attachment,
}: {
  attachment: Extract<
    ChatMessageAttachmentPresentation,
    { kind: "urlPreview" }
  >
}) {
  const thumbnailUrl = useInlineMediaUrl(
    attachment.thumbnail?.mediaKey,
    attachment.thumbnail?.remoteUrl,
  )
  const className = stylex.props(styles.item, styles.urlPreview).className ?? ""
  return (
    <AttachmentLink
      url={attachment.url}
      label={`Open ${attachment.title}`}
      className={className}
    >
      <span aria-hidden="true" {...stylex.props(styles.accent)} />
      {attachment.thumbnail ? (
        <span {...stylex.props(styles.thumbnail)}>
          {thumbnailUrl ? <img src={thumbnailUrl} alt="" {...stylex.props(styles.image)} /> : null}
        </span>
      ) : null}
      <span {...stylex.props(styles.copy)}>
        <span {...stylex.props(styles.title)}>{attachment.title}</span>
        {attachment.subtitle ? (
          <span {...stylex.props(styles.subtitle)}>{attachment.subtitle}</span>
        ) : null}
      </span>
    </AttachmentLink>
  )
}

function ExternalTaskAttachmentView({
  attachment,
}: {
  attachment: Extract<
    ChatMessageAttachmentPresentation,
    { kind: "externalTask" }
  >
}) {
  const assignee = useInlineObject<DbObjectKind.User, User>(
    DbObjectKind.User,
    attachment.assignedUserId,
  )
  const name =
    [assignee?.firstName, assignee?.lastName].filter(Boolean).join(" ") ||
    assignee?.username
  const application = attachment.application
    ? attachment.application[0]!.toUpperCase() + attachment.application.slice(1)
    : "Task"
  const creator = name
    ? `${name} ${attachment.application?.toLowerCase() === "linear" ? "created a Linear issue" : "will do"}`
    : "Unassigned"
  const className = stylex.props(styles.item, styles.externalTask).className ?? ""

  return (
    <AttachmentLink
      url={attachment.url}
      label={`Open ${attachment.title}`}
      className={className}
    >
      <span {...stylex.props(styles.taskMeta)}>
        {assignee ? <UserAvatar user={assignee} size={16} /> : null}
        <span {...stylex.props(styles.subtitle)}>{creator}</span>
      </span>
      <span {...stylex.props(styles.taskLine)}>
        <span aria-hidden="true" {...stylex.props(styles.taskSquare)} />
        <span {...stylex.props(styles.title)}>{attachment.title}</span>
        <span {...stylex.props(styles.taskNumber)}>
          {[application, attachment.number].filter(Boolean).join(" ")}
        </span>
      </span>
    </AttachmentLink>
  )
}

function UnsupportedAttachmentView() {
  return (
    <span {...stylex.props(styles.item, styles.unsupported)}>
      Attachment
    </span>
  )
}

export function MessageAttachmentsView({
  attachments,
}: {
  attachments: ChatMessageAttachmentPresentation[]
}) {
  return (
    <span {...stylex.props(styles.root)}>
      {attachments.map((attachment) => {
        switch (attachment.kind) {
          case "urlPreview":
            return <URLPreviewAttachmentView key={attachment.key} attachment={attachment} />
          case "externalTask":
            return <ExternalTaskAttachmentView key={attachment.key} attachment={attachment} />
          case "unsupported":
            return <UnsupportedAttachmentView key={attachment.key} />
        }
      })}
    </span>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 4,
  },
  item: {
    width: 250,
    maxWidth: "min(250px, calc(100vw - 116px))",
    display: "flex",
    overflow: "hidden",
    borderRadius: 8,
    backgroundColor: "rgba(127,127,127,.13)",
    color: "inherit",
    textDecoration: "none",
  },
  urlPreview: {
    height: 40,
    alignItems: "center",
    gap: 7,
    paddingInlineEnd: 6,
  },
  accent: {
    width: 3,
    height: "100%",
    flexShrink: 0,
    backgroundColor: "currentColor",
    opacity: 0.48,
  },
  thumbnail: {
    width: 32,
    height: 32,
    display: "block",
    flexShrink: 0,
    overflow: "hidden",
    borderRadius: 6,
    backgroundColor: "rgba(127,127,127,.13)",
  },
  image: {
    width: "100%",
    height: "100%",
    display: "block",
    objectFit: "cover",
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flex: 1,
    flexDirection: "column",
    justifyContent: "center",
    gap: 1,
  },
  title: {
    minWidth: 0,
    overflow: "hidden",
    fontSize: 11,
    fontWeight: 500,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  subtitle: {
    minWidth: 0,
    overflow: "hidden",
    opacity: 0.66,
    fontSize: 9,
    lineHeight: 1.15,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  externalTask: {
    height: 46,
    flexDirection: "column",
    justifyContent: "center",
    gap: 2,
    paddingBlock: 5,
    paddingInline: 6,
  },
  taskMeta: {
    minWidth: 0,
    display: "flex",
    alignItems: "center",
    gap: 4,
  },
  taskLine: {
    minWidth: 0,
    display: "flex",
    alignItems: "center",
    gap: 5,
  },
  taskSquare: {
    width: 10,
    height: 10,
    flexShrink: 0,
    borderWidth: 2,
    borderStyle: "solid",
    borderColor: "currentColor",
    borderRadius: 3,
    opacity: 0.66,
  },
  taskNumber: {
    marginInlineStart: "auto",
    opacity: 0.52,
    fontSize: 9,
    whiteSpace: "nowrap",
  },
  unsupported: {
    height: 40,
    alignItems: "center",
    paddingInline: 9,
    opacity: 0.7,
    fontSize: 10,
  },
})
