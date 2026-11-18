import {
  AgentGrantRequirement,
  BlockContent,
  BlockFormText_Kind,
  BlockList_Kind,
  MessageAction_Style,
  MessageActions,
  MessageEntities,
  MessageEntity_Type,
  MessageFwdHeader,
  MessageMedia,
  Photo_Format,
  type Block,
  type BlockText,
  type Message,
  type MessageEntity,
  type Photo,
  type PhotoSize,
} from "@inline-chat/protocol/core"
import {
  demoPngSize,
  demoStripped,
  demoWaveform,
  demoWavSize,
  mixSeed,
} from "./demo-bytes"
import { SeededRandom } from "./rng"
import type { ModelMessage } from "./server-model"

/**
 * What a demo message carries beyond its text: media, entities, a forward
 * header, bot buttons and rich blocks. Seeded messages get theirs from a
 * stream of their own (`seededContent`), so their text, author and date
 * streams stay as they were; live and sent messages carry theirs as data.
 *
 * Media is described by a spec (`DemoMediaSpec`) and encoded on the way out
 * (`encodeMedia`, memoized): file IDs name everything needed to make the
 * bytes again (`demo-transfers.ts` parses them), and sizes are known without
 * making them, so nothing is generated until a client downloads it.
 */

export type DemoPhotoShape = "landscape" | "wide" | "portrait" | "square" | "tall" | "panorama"

export type DemoMediaSpec =
  | { kind: "photo"; seed: number; w: number; h: number }
  | { kind: "video"; seed: number; w: number; h: number; duration: number; size: number }
  | { kind: "document"; seed: number; fileName: string; mimeType: string; size: number }
  | { kind: "voice"; seed: number; duration: number }
  /** An uploaded file, as the server encoded it at finalization. */
  | { kind: "wire"; media: MessageMedia }

export type DemoExtras = {
  media?: DemoMediaSpec
  entities?: MessageEntity[]
  fwdFrom?: MessageFwdHeader
  actions?: MessageActions
  blockContent?: BlockContent
}

/** A model message with its demo content. */
export type DemoModelMessage = ModelMessage & { extras?: DemoExtras }

export const extrasOf = (message: ModelMessage | undefined): DemoExtras | undefined =>
  (message as DemoModelMessage | undefined)?.extras

// ---- Media ----------------------------------------------------------------------

const SHAPES: Record<DemoPhotoShape, readonly [number, number]> = {
  landscape: [4_032, 3_024],
  wide: [1_920, 1_080],
  portrait: [3_024, 4_032],
  square: [2_048, 2_048],
  tall: [1_170, 4_160],
  panorama: [6_000, 1_200],
}

const SHAPE_WEIGHTS: Record<DemoPhotoShape, number> = {
  landscape: 30,
  wide: 18,
  portrait: 22,
  square: 10,
  tall: 10,
  panorama: 10,
}

export const photoSpec = (seed: number, shape: DemoPhotoShape): DemoMediaSpec => {
  const [w, h] = SHAPES[shape]
  return { kind: "photo", seed, w, h }
}

const fit = (w: number, h: number, box: number) => {
  const scale = Math.min(1, box / Math.max(w, h))
  return { w: Math.max(1, Math.round(w * scale)), h: Math.max(1, Math.round(h * scale)) }
}

/** File IDs: everything `demo-transfers.ts` needs to make the bytes again. */
export const demoFileIds = {
  photo: (seed: number, w: number, h: number) => `dp_${seed}_${w}x${h}`,
  video: (seed: number, size: number) => `dv_${seed}_${size}`,
  document: (seed: number, size: number, csv: boolean) => `dd_${seed}_${size}_${csv ? "c" : "t"}`,
  voice: (seed: number, duration: number) => `da_${seed}_${duration}`,
}

const photoSizes = (seed: number, w: number, h: number, boxes: ReadonlyArray<readonly [string, number]>): PhotoSize[] => {
  const tiny = fit(w, h, 40)
  const sizes: PhotoSize[] = [{ type: "s", w: tiny.w, h: tiny.h, size: 0, bytes: demoStripped(seed, w, h) }]
  for (const [type, box] of boxes) {
    const size = fit(w, h, box)
    sizes.push({
      type,
      w: size.w,
      h: size.h,
      size: demoPngSize(size.w, size.h),
      fileUniqueId: demoFileIds.photo(seed, size.w, size.h),
    })
  }
  return sizes
}

const photoWire = (id: bigint, date: bigint, seed: number, w: number, h: number, boxes: ReadonlyArray<readonly [string, number]>): Photo => {
  const sizes = photoSizes(seed, w, h, boxes)
  return {
    id,
    date,
    format: Photo_Format.PNG,
    sizes,
    ...(sizes.at(-1)?.fileUniqueId ? { fileUniqueId: sizes.at(-1)!.fileUniqueId! } : {}),
  }
}

/** A generated poster for a video uploaded without one (sizes `s` and `c`). */
export const demoThumbnail = (id: bigint, date: bigint, seed: number, w: number, h: number): Photo =>
  photoWire(id, date, seed, Math.max(1, w), Math.max(1, h), [["c", 320]])

const PHOTO_BOXES = [
  ["b", 160],
  ["c", 320],
  ["d", 800],
] as const

const memo = new Map<string, MessageMedia>()
const MEMO_LIMIT = 2_000

/** The wire media for a spec, for the message `(chatId, messageId)`. */
export const encodeMedia = (spec: DemoMediaSpec, chatId: bigint, messageId: bigint, date: bigint): MessageMedia => {
  if (spec.kind === "wire") return spec.media
  const key = `${spec.kind}:${spec.seed}:${chatId}:${messageId}`
  const cached = memo.get(key)
  if (cached) return cached
  const id = (chatId * 1_000_000n + messageId) * 4n
  let media: MessageMedia
  switch (spec.kind) {
    case "photo":
      media = { media: { oneofKind: "photo", photo: { photo: photoWire(id, date, spec.seed, spec.w, spec.h, PHOTO_BOXES) } } }
      break
    case "video": {
      const thumbnail = photoWire(id + 1n, date, spec.seed, spec.w, spec.h, [["c", 320]])
      media = {
        media: {
          oneofKind: "video",
          video: {
            video: {
              id,
              date,
              w: spec.w,
              h: spec.h,
              duration: spec.duration,
              size: spec.size,
              photo: thumbnail,
              hasAudio: true,
              fileUniqueId: demoFileIds.video(spec.seed, spec.size),
            },
          },
        },
      }
      break
    }
    case "document":
      media = {
        media: {
          oneofKind: "document",
          document: {
            document: {
              id,
              date,
              fileName: spec.fileName,
              mimeType: spec.mimeType,
              size: spec.size,
              fileUniqueId: demoFileIds.document(spec.seed, spec.size, spec.mimeType === "text/csv"),
            },
          },
        },
      }
      break
    case "voice":
      media = {
        media: {
          oneofKind: "voice",
          voice: {
            voice: {
              id,
              date,
              duration: spec.duration,
              size: demoWavSize(spec.duration),
              mimeType: "audio/wav",
              waveform: demoWaveform(spec.seed),
              fileUniqueId: demoFileIds.voice(spec.seed, spec.duration),
            },
          },
        },
      }
      break
  }
  if (memo.size >= MEMO_LIMIT) memo.delete(memo.keys().next().value!)
  memo.set(key, media)
  return media
}

/** What `searchMessages` filters by. */
export const mediaKindOf = (extras: DemoExtras | undefined): "photo" | "video" | "document" | "voice" | undefined => {
  const media = extras?.media
  if (!media) return undefined
  if (media.kind !== "wire") return media.kind
  const kind = media.media.media.oneofKind
  return kind === "photo" || kind === "video" || kind === "document" || kind === "voice" ? kind : undefined
}

const DOCUMENTS = [
  ["Q4 plan.txt", "text/plain"],
  ["metrics.csv", "text/csv"],
  ["release notes.md", "text/markdown"],
  ["onboarding checklist.txt", "text/plain"],
  ["export-2026-11.csv", "text/csv"],
  ["design assets.zip", "application/zip"],
] as const

/** A media spec of the given kind from a stream. */
export const mediaSpec = (
  random: SeededRandom,
  kind: "photo" | "video" | "document" | "voice",
  shape?: DemoPhotoShape,
): DemoMediaSpec => {
  const seed = Math.floor(random.next() * 0xffff_ffff) >>> 0
  switch (kind) {
    case "photo":
      return photoSpec(seed, shape ?? random.weighted(SHAPE_WEIGHTS))
    case "video": {
      const portrait = random.bool(0.3)
      return {
        kind: "video",
        seed,
        w: portrait ? 1_080 : 1_920,
        h: portrait ? 1_920 : 1_080,
        duration: random.int(3, 90),
        size: random.int(150_000, 1_500_000),
      }
    }
    case "document": {
      const [fileName, mimeType] = random.pick(DOCUMENTS)
      return { kind: "document", seed, fileName, mimeType, size: random.int(800, 60_000) }
    }
    case "voice":
      return { kind: "voice", seed, duration: random.int(2, 40) }
  }
}

// ---- Entities -------------------------------------------------------------------

const entity = (
  type: MessageEntity_Type,
  offset: number,
  length: number,
  extra: MessageEntity["entity"] = { oneofKind: undefined },
): MessageEntity => ({ type, offset: BigInt(offset), length: BigInt(length), entity: extra })

const LINKS = ["https://inline.chat/docs/sync", "https://example.com/spec/rollout", "https://status.example.com/incidents/42"]

/**
 * Rewrite a text with entities of one kind or a mix: a mention of a member,
 * bold, italic, inline code, a code block, a link, a text link, an email,
 * underline or strikethrough. Offsets are UTF-16, as the protocol's are.
 */
export const withEntities = (
  random: SeededRandom,
  text: string,
  mentionable: ReadonlyArray<{ id: bigint; name: string }>,
  /** 0 mention, 1 bold, 2 italic, 3 code, 4 code block, 5 link, 6 text link, 7 email, 8 underline or strikethrough. */
  variant = random.int(0, 8),
): { text: string; entities: MessageEntity[] } => {
  const words = text.split(" ")
  const first = words[0] ?? text
  switch (variant) {
    case 0: {
      const person = mentionable.length > 0 ? random.pick(mentionable) : undefined
      if (!person) break
      const mention = `@${person.name}`
      return {
        text: `${mention} ${text}`,
        entities: [
          entity(MessageEntity_Type.MENTION, 0, mention.length, { oneofKind: "mention", mention: { userId: person.id } }),
        ],
      }
    }
    case 1:
      return { text, entities: [entity(MessageEntity_Type.BOLD, 0, first.length)] }
    case 2: {
      const last = words.at(-1) ?? text
      return { text, entities: [entity(MessageEntity_Type.ITALIC, text.length - last.length, last.length)] }
    }
    case 3: {
      const code = random.pick(["bun run typecheck", "git rebase --onto main", "SELECT count(*) FROM dialogs", "vite build"])
      const prefix = `${text} — run `
      return { text: `${prefix}${code}`, entities: [entity(MessageEntity_Type.CODE, prefix.length, code.length)] }
    }
    case 4: {
      const block = random.pick([
        "const total = rows.reduce((sum, row) => sum + row.count, 0)\nconsole.log(total)",
        "func reload() async throws {\n  try await sync.run()\n}",
        "{\n  \"rollout\": 0.25,\n  \"regions\": [\"eu\", \"us\"]\n}",
      ])
      const language = block.startsWith("func") ? "swift" : block.startsWith("{") ? "json" : "ts"
      const prefix = `${text}\n`
      return {
        text: `${prefix}${block}`,
        entities: [entity(MessageEntity_Type.PRE, prefix.length, block.length, { oneofKind: "pre", pre: { language } })],
      }
    }
    case 5: {
      const url = random.pick(LINKS)
      const prefix = `${text} `
      return { text: `${prefix}${url}`, entities: [entity(MessageEntity_Type.URL, prefix.length, url.length)] }
    }
    case 6: {
      const label = "the spec"
      const prefix = `${text} (see `
      return {
        text: `${prefix}${label})`,
        entities: [
          entity(MessageEntity_Type.TEXT_URL, prefix.length, label.length, {
            oneofKind: "textUrl",
            textUrl: { url: random.pick(LINKS) },
          }),
        ],
      }
    }
    case 7: {
      const email = "ops@example.com"
      const prefix = `${text} — mail `
      return { text: `${prefix}${email}`, entities: [entity(MessageEntity_Type.EMAIL, prefix.length, email.length)] }
    }
    default:
      return {
        text,
        entities: [
          entity(random.bool() ? MessageEntity_Type.UNDERLINE : MessageEntity_Type.STRIKETHROUGH, 0, first.length),
        ],
      }
  }
  return { text, entities: [entity(MessageEntity_Type.BOLD, 0, first.length)] }
}

const EMOJI = ["👍", "🎉", "🚀", "🔥", "✅", "🙏", "😂", "❤️", "👀", "🤝", "💯", "😅"]

export const emojiOnly = (random: SeededRandom) =>
  Array.from({ length: random.int(1, 3) }, () => random.pick(EMOJI)).join("")

// ---- Bot content ----------------------------------------------------------------

export type DemoBotTemplate = "summary" | "buttons" | "form"

class RangeText {
  text = ""

  add(value: string): BlockText {
    const offset = this.text.length
    this.text += value
    return { offset: BigInt(offset), length: BigInt(value.length) }
  }

  line(value: string): BlockText {
    if (this.text.length > 0) this.text += "\n"
    return this.add(value)
  }
}

/** A bot message: text plus blocks (ranges into it) and buttons. */
export const botMessage = (
  template: DemoBotTemplate,
  random: SeededRandom,
): { text: string; extras: DemoExtras } => {
  const text = new RangeText()
  const build = random.int(1_000, 9_999)
  switch (template) {
    case "summary": {
      const heading = text.line(`Deploy summary for build ${build}`)
      const paragraph = text.line("Everything passed. Rollout starts in the EU region, then the US.")
      const items = ["Migrations applied", "Canary healthy for 30 minutes", "Error rate under 0.1%"].map((item) =>
        text.line(item),
      )
      const code = text.line(`inline deploy --build ${build} --region eu`)
      const blocks: Block[] = [
        { kind: { oneofKind: "heading", heading: { text: heading, level: 2 } } },
        { kind: { oneofKind: "paragraph", paragraph } },
        {
          kind: {
            oneofKind: "list",
            list: {
              kind: BlockList_Kind.UNORDERED,
              items: items.map((item) => ({ children: [{ kind: { oneofKind: "paragraph", paragraph: item } }] })),
            },
          },
        },
        { kind: { oneofKind: "code", code: { text: code, language: "sh" } } },
      ]
      return { text: text.text, extras: { blockContent: { blocks } } }
    }
    case "buttons": {
      const paragraph = text.line(`Build ${build} is ready. Approve the rollout to production?`)
      return {
        text: text.text,
        extras: {
          blockContent: { blocks: [{ kind: { oneofKind: "paragraph", paragraph } }] },
          actions: {
            rows: [
              {
                actions: [
                  callback("approve", "Approve", MessageAction_Style.PRIMARY),
                  callback("reject", "Reject", MessageAction_Style.DESTRUCTIVE),
                ],
              },
              {
                actions: [
                  {
                    actionId: "dashboard",
                    text: "Open dashboard",
                    action: { oneofKind: "openUrl", openUrl: { url: "https://inline.chat" } },
                    style: MessageAction_Style.DEFAULT,
                    requiredGrant: AgentGrantRequirement.NONE,
                  },
                  {
                    actionId: "copy-build",
                    text: "Copy build ID",
                    action: { oneofKind: "copyText", copyText: { text: String(build) } },
                    style: MessageAction_Style.DEFAULT,
                    requiredGrant: AgentGrantRequirement.NONE,
                  },
                ],
              },
            ],
          },
        },
      }
    }
    case "form": {
      const intro = text.line(`Before build ${build} ships, a few questions.`)
      const title = text.line("Release checklist")
      const environment = text.line("Environment")
      const staging = text.line("Staging")
      const production = text.line("Production")
      const notes = text.line("Notes for the team")
      const notify = text.line("Notify the channel")
      const rollout = text.line("Rollout percentage")
      const blocks: Block[] = [
        { kind: { oneofKind: "paragraph", paragraph: intro } },
        {
          kind: {
            oneofKind: "form",
            form: {
              formId: "release-checklist",
              title,
              submitLabel: "Ship it",
              requiredGrant: AgentGrantRequirement.NONE,
              closed: false,
              fields: [
                {
                  fieldId: "environment",
                  label: environment,
                  required: true,
                  kind: {
                    oneofKind: "select",
                    select: {
                      options: [
                        { optionId: "staging", label: staging, recommended: true },
                        { optionId: "production", label: production, recommended: false },
                      ],
                      multiple: false,
                      defaultOptionIds: ["staging"],
                      allowOther: false,
                    },
                  },
                },
                {
                  fieldId: "notes",
                  label: notes,
                  required: false,
                  kind: {
                    oneofKind: "text",
                    text: { kind: BlockFormText_Kind.MULTILINE, placeholder: "Anything to watch for?" },
                  },
                },
                {
                  fieldId: "notify",
                  label: notify,
                  required: false,
                  kind: { oneofKind: "toggle", toggle: { defaultValue: true } },
                },
                {
                  fieldId: "rollout",
                  label: rollout,
                  required: true,
                  kind: {
                    oneofKind: "number",
                    number: { defaultValue: 25, min: 1, max: 100, step: 1, integer: true },
                  },
                },
              ],
            },
          },
        },
      ]
      return { text: text.text, extras: { blockContent: { blocks } } }
    }
  }
}

const callback = (actionId: string, text: string, style: MessageAction_Style) => ({
  actionId,
  text,
  action: { oneofKind: "callback" as const, callback: { data: new TextEncoder().encode(actionId) } },
  style,
  requiredGrant: AgentGrantRequirement.NONE,
})

/** The form of a bot message, closed (answered), or undefined when it has none. */
export const closeForm = (extras: DemoExtras | undefined, formId: string): DemoExtras | undefined => {
  const blocks = extras?.blockContent?.blocks
  if (!blocks?.some((block) => block.kind.oneofKind === "form" && block.kind.form.formId === formId)) return undefined
  return {
    ...extras,
    blockContent: {
      blocks: blocks.map((block) =>
        block.kind.oneofKind === "form" && block.kind.form.formId === formId
          ? { kind: { oneofKind: "form", form: { ...block.kind.form, closed: true } } }
          : block,
      ),
    },
  }
}

// ---- Seeded content ---------------------------------------------------------------

export type SeededContentContext = {
  seed: number
  chatId: bigint
  messageId: bigint
  /** The chat has the agent among its members (bot content). */
  agent: bigint | undefined
  /** People a mention may name. */
  mentionable: ReadonlyArray<{ id: bigint; name: string }>
  /** A message elsewhere to forward from. */
  forwardSource: (random: SeededRandom) => { chatId: bigint; fromId: bigint; messageId: bigint } | undefined
}

/**
 * What a seeded message carries besides its text, from a stream of its own:
 * about 11% media (photos of every shape, videos, documents, voice notes),
 * 10% entities, 2.5% emoji only, 2% forwarded, 4% edited, and in chats with
 * the agent a share of bot messages with blocks, buttons or a form.
 */
export const seededContent = (
  context: SeededContentContext,
  base: { text: string; fromId: bigint; date: bigint },
): { text: string; fromId: bigint; editDate?: bigint; extras?: DemoExtras } => {
  const random = new SeededRandom(mixSeed(context.seed, 0x2545f491, Number(context.chatId), Number(context.messageId)))
  if (context.agent != null && random.bool(0.14)) {
    const template = random.pick(["summary", "buttons", "form"] as const)
    const bot = botMessage(template, random)
    return { text: bot.text, fromId: context.agent, extras: bot.extras }
  }
  const roll = random.next()
  let text = base.text
  const extras: DemoExtras = {}
  if (roll < 0.11) {
    const kind = random.weighted({ photo: 62, video: 12, document: 14, voice: 12 })
    extras.media = mediaSpec(random, kind)
    if (kind === "voice" || random.bool(kind === "photo" ? 0.6 : 0.7)) text = ""
  } else if (roll < 0.21) {
    const rewritten = withEntities(random, text, context.mentionable)
    text = rewritten.text
    extras.entities = rewritten.entities
  } else if (roll < 0.235) {
    text = emojiOnly(random)
  }
  if (extras.media == null && random.bool(0.02)) {
    const source = context.forwardSource(random)
    if (source) {
      extras.fwdFrom = {
        fromPeerId: { type: { oneofKind: "chat", chat: { chatId: source.chatId } } },
        fromId: source.fromId,
        fromMessageId: source.messageId,
      }
    }
  }
  const edited = text.length > 0 && random.bool(0.04)
  return {
    text,
    fromId: base.fromId,
    ...(edited ? { editDate: base.date + BigInt(random.int(30, 3_600)) } : {}),
    ...(Object.keys(extras).length > 0 ? { extras } : {}),
  }
}

/** Seeded holes: about 1.5% of a chat's seeded IDs were deleted long ago (never the newest). */
export const seededHole = (seed: number, chatId: bigint, messageId: bigint, count: number) =>
  messageId < BigInt(count) && new SeededRandom(mixSeed(seed, 0x68e31da4, Number(chatId), Number(messageId))).bool(0.015)

// ---- Wire ---------------------------------------------------------------------------

/** The content fields of the wire message for these extras. */
export const encodeExtras = (
  extras: DemoExtras,
  chatId: bigint,
  messageId: bigint,
  date: bigint,
): Partial<Message> => ({
  ...(extras.media ? { media: encodeMedia(extras.media, chatId, messageId, date) } : {}),
  ...(extras.entities && extras.entities.length > 0 ? { entities: { entities: extras.entities } } : {}),
  ...(extras.fwdFrom ? { fwdFrom: extras.fwdFrom } : {}),
  ...(extras.actions ? { actions: extras.actions } : {}),
  ...(extras.blockContent ? { blockContent: extras.blockContent } : {}),
})

/** Extras as JSON for the saved state (bytes as base64, IDs as strings). */
export const extrasToJson = (extras: DemoExtras): unknown => ({
  ...(extras.media
    ? {
        media:
          extras.media.kind === "wire"
            ? { kind: "wire", media: MessageMedia.toJson(extras.media.media) }
            : extras.media,
      }
    : {}),
  ...(extras.entities ? { entities: MessageEntities.toJson({ entities: extras.entities }) } : {}),
  ...(extras.fwdFrom ? { fwdFrom: MessageFwdHeader.toJson(extras.fwdFrom) } : {}),
  ...(extras.actions ? { actions: MessageActions.toJson(extras.actions) } : {}),
  ...(extras.blockContent ? { blockContent: BlockContent.toJson(extras.blockContent) } : {}),
})

/** The inverse of `extrasToJson`; undefined for anything it does not recognize. */
export const extrasFromJson = (value: unknown): DemoExtras | undefined => {
  if (value == null || typeof value !== "object") return undefined
  const json = value as Record<string, unknown>
  try {
    const extras: DemoExtras = {}
    const media = json.media as Record<string, unknown> | undefined
    if (media && typeof media === "object") {
      if (media.kind === "wire") {
        extras.media = { kind: "wire", media: MessageMedia.fromJson(media.media as never) }
      } else if (media.kind === "photo" || media.kind === "video" || media.kind === "document" || media.kind === "voice") {
        extras.media = media as DemoMediaSpec
      }
    }
    if (json.entities) extras.entities = MessageEntities.fromJson(json.entities as never).entities
    if (json.fwdFrom) extras.fwdFrom = MessageFwdHeader.fromJson(json.fwdFrom as never)
    if (json.actions) extras.actions = MessageActions.fromJson(json.actions as never)
    if (json.blockContent) extras.blockContent = BlockContent.fromJson(json.blockContent as never)
    return extras
  } catch {
    return undefined
  }
}
