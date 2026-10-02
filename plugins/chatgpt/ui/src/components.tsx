import { useEffect, useState, type CSSProperties, type ReactNode } from "react"
import { safeUrl, senderName, type Message, type ThreadSnapshot } from "./contracts"

export function Icon({ name }: { name: "refresh" | "send" | "reply" | "select" | "check" | "close" | "chevron" | "thread" }) {
  const paths = {
    refresh: <><path d="M18.5 7A7 7 0 1 0 19 13"/><path d="M18.5 3v4.5H14"/></>,
    send: <><path d="m5 12 7-7 7 7M12 5v14"/></>,
    reply: <><path d="m9 6-6 5 6 5M3 11h9a7 7 0 0 1 7 7"/></>,
    select: <rect x="5" y="5" width="14" height="14" rx="4"/>,
    check: <path d="m6 12 4 4 8-8"/>,
    close: <path d="m7 7 10 10M7 17 17 7"/>,
    chevron: <path d="m8 10 4 4 4-4"/>,
    thread: <><path d="M5 5h14v11H9l-4 3V5Z"/><path d="M9 9h6M9 12h4"/></>,
  }
  return <svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>
}

// Same palette and UTF-8 seed algorithm as InlineAvatarCore.
const avatarColors = ["#db2678", "#ff9400", "#8a52eb", "#dba305", "#00a194", "#057aff", "#00b8a6", "#33ad4d", "#eb3833", "#5957d6", "#1fb87a", "#00addb"]
function brighterAvatar(color: string): string {
  const values = [1, 3, 5].map((offset) => Number.parseInt(color.slice(offset, offset + 2), 16) / 255)
  const [red, green, blue] = values as [number, number, number]
  const maximum = Math.max(...values), minimum = Math.min(...values), delta = maximum - minimum
  const lightness = (maximum + minimum) / 2
  const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1))
  const hue = delta === 0 ? 0 : maximum === red ? ((green - blue) / delta + (green < blue ? 6 : 0))
    : maximum === green ? (blue - red) / delta + 2 : (red - green) / delta + 4
  return `hsl(${hue * 60} ${saturation * 100}% ${Math.min(1, lightness + 0.2) * 100}%)`
}
export function Avatar({ name, url, hidden = false }: { name: string; url?: string; hidden?: boolean }) {
  const [failed, setFailed] = useState(false)
  const seed = new TextEncoder().encode(name.trim())
  const color = avatarColors[seed.reduce((sum, byte) => (sum + byte) % avatarColors.length, 0)]!
  const image = safeUrl(url)
  return <span className={`avatar${hidden ? " avatar-hidden" : ""}`} style={{ "--avatar-color": color, "--avatar-start": brighterAvatar(color) } as CSSProperties} aria-hidden="true">
    {image && !failed ? <img src={image} alt="" onError={() => setFailed(true)} /> : Array.from(name.trim())[0]?.toUpperCase() || "?"}
  </span>
}

export function messageDate(value: string | null): Date | null {
  if (value === null || !/^\d+$/.test(value)) return null
  const date = new Date(Number(value) * 1000)
  return Number.isFinite(date.getTime()) ? date : null
}
const dayFormat = new Intl.DateTimeFormat(undefined, { month: "long", day: "numeric", year: "numeric" })
const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" })
export function dayKey(message: Message): string { return messageDate(message.date)?.toDateString() || "unknown" }
export function dayLabel(message: Message): string {
  const date = messageDate(message.date)
  if (!date) return ""
  const today = new Date()
  const yesterday = new Date(today)
  yesterday.setDate(yesterday.getDate() - 1)
  return date.toDateString() === today.toDateString() ? "Today" : date.toDateString() === yesterday.toDateString() ? "Yesterday" : dayFormat.format(date)
}
export function grouped(first: Message | undefined, second: Message | undefined): boolean {
  if (!first || !second || first.out !== second.out || first.fromId !== second.fromId || dayKey(first) !== dayKey(second)) return false
  const firstDate = messageDate(first.date), secondDate = messageDate(second.date)
  return !!firstDate && !!secondDate && Math.abs(firstDate.getTime() - secondDate.getTime()) < 300_000
}

function TextContent({ text, links }: { text: string; links: string[] }) {
  const nodes: ReactNode[] = []
  let remaining = text
  let index = 0
  // Only link exact URLs already returned by Inline; ordinary text stays literal.
  const urls = links.map(safeUrl).filter((url): url is string => !!url).slice(0, 30)
  while (remaining) {
    const match = urls.map((url) => ({ url, position: remaining.indexOf(url) })).filter((item) => item.position >= 0)
      .sort((left, right) => left.position - right.position)[0]
    if (!match) { nodes.push(remaining); break }
    nodes.push(remaining.slice(0, match.position))
    nodes.push(<a key={index++} href={match.url} target="_blank" rel="noopener noreferrer">{match.url}</a>)
    remaining = remaining.slice(match.position + match.url.length)
  }
  return <div className="message-text" dir="auto">{nodes}</div>
}

function MediaContent({ message }: { message: Message }) {
  const [failed, setFailed] = useState(false)
  const media = message.media
  const latestUrl = safeUrl(media?.url)
  const [source, setSource] = useState(latestUrl)
  useEffect(() => {
    if ((!source || failed) && latestUrl && latestUrl !== source) { setSource(latestUrl); setFailed(false) }
  }, [latestUrl, source, failed])
  if (!media) return null
  const url = source
  // Re-signed URLs must not restart playback or refetch an already displayed photo.
  const unavailable = () => { if (latestUrl && latestUrl !== source) { setSource(latestUrl); setFailed(false) } else setFailed(true) }
  if (media.kind === "nudge") return <p className="nudge">👋 Nudge</p>
  if (url && !failed && media.kind === "photo") return <a className="photo-link" href={latestUrl || url} target="_blank" rel="noopener noreferrer">
    <img className="message-photo" src={url} alt={message.text ? "Attached photo" : "Photo"} loading="lazy" onError={unavailable}
      style={{ aspectRatio: media.width && media.height ? `${media.width}/${media.height}` : "4/3" }} />
  </a>
  if (url && !failed && media.kind === "video") return <video className="message-video" src={url} controls preload="metadata" onError={unavailable} />
  if (url && !failed && media.kind === "voice") return <audio className="message-audio" src={url} controls preload="metadata" onError={unavailable} />
  const title = media.fileName || ({ photo: "Photo", video: "Video", document: "Document", voice: "Voice message", nudge: "Nudge" }[media.kind])
  return latestUrl ? <a className="attachment" href={latestUrl} target="_blank" rel="noopener noreferrer">{title} <span aria-hidden="true">↗</span></a>
    : <span className="attachment">{title}</span>
}

export function MessageRow({ message, snapshot, previous, next, selected, canSelect, canReply, onSelect, onReply }: {
  message: Message
  snapshot: ThreadSnapshot
  previous?: Message
  next?: Message
  selected: boolean
  canSelect: boolean
  canReply: boolean
  onSelect: () => void
  onReply: () => void
}) {
  const name = senderName(message, snapshot)
  const first = !grouped(previous, message), last = !grouped(message, next)
  const replied = snapshot.messages.find((row) => row.id === message.replyToMsgId)
  const date = messageDate(message.date)
  const avatar = snapshot.participants?.find((person) => person.userId === message.fromId)?.avatarUrl
  return <li className={`message-row ${message.out ? "outgoing" : "incoming"}${first ? " first-in-group" : ""}${last ? " last-in-group" : ""}${selected ? " selected" : ""}`} data-message-id={message.id}>
    {!message.out && <Avatar key={`${message.fromId}:${avatar}`} name={name} url={avatar} hidden={!last} />}
    <div className="message-stack">
      {first && !message.out && snapshot.chat.kind !== "dm" && <div className="sender-name">{name}</div>}
      <div className="bubble">
        {message.replyToMsgId && <div className="quoted-message" dir="auto">
          <strong>{replied ? senderName(replied, snapshot) : "Reply"}</strong>
          <span>{replied?.text || (replied?.media ? "Attachment" : "Earlier message")}</span>
        </div>}
        <MediaContent key={`${message.media?.kind}:${message.media?.id ?? message.id}`} message={message} />
        {message.text && <TextContent text={message.text} links={message.links} />}
        {!message.text && !message.media && <span className="empty-message">Empty message</span>}
        <div className="message-time">
          {message.editDate && <span>edited </span>}
          {date && <time dateTime={date.toISOString()} title={date.toLocaleString()}>{timeFormat.format(date)}</time>}
        </div>
      </div>
    </div>
    {(canSelect || canReply) && <div className="message-actions">
      {canReply && <button className="icon-button" type="button" aria-label={`Reply to ${name}'s message`} title="Reply" onClick={onReply}><Icon name="reply" /></button>}
      {canSelect && <button className="icon-button" type="button" aria-label={`Select ${name}'s message for ChatGPT`} aria-pressed={selected} title="Select for ChatGPT" onClick={onSelect}><Icon name={selected ? "check" : "select"} /></button>}
    </div>}
  </li>
}
