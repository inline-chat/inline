import { describe, expect, test } from "bun:test"
import {
  AgentGrantOperation,
  AgentGrantRequirement,
  BlockFormText_Kind,
  MessageAction_Style,
  type BlockContent,
  type BlockForm,
  type BlockText,
  type MessageActions,
} from "@inline-chat/protocol/core"
import { operationsToMask, satisfiesGrantRequirement, type AgentAccess } from "@in/server/modules/agents/grants"
import { validateBlockContent } from "@in/server/modules/message/blockContent"
import { validateBotBlockContent } from "@in/server/modules/message/botBlockContent"
import { normalizeAndValidateMessageActions } from "@in/server/modules/message/messageActions"
import { validateFormSubmission } from "@in/server/modules/message/messageForms"

/** Fallback text plus ranges into it, the way a bot builds structured content. */
function builder() {
  let text = ""
  const range = (value: string): BlockText => {
    const offset = text.length
    text += value + "\n"
    return { offset: BigInt(offset), length: BigInt(value.length) }
  }
  return { range, text: () => text }
}

function approvalForm(): { text: string; form: BlockForm } {
  const b = builder()
  const form: BlockForm = {
    formId: "question.1",
    title: b.range("Which branch?"),
    fields: [
      {
        fieldId: "branch",
        label: b.range("Branch"),
        required: true,
        kind: {
          oneofKind: "select",
          select: {
            options: [
              { optionId: "main", label: b.range("1. main") },
              { optionId: "dev", label: b.range("2. dev") },
            ],
            multiple: false,
            defaultOptionIds: [],
            allowOther: true,
          },
        },
      },
      {
        fieldId: "token",
        label: b.range("Token"),
        required: false,
        kind: { oneofKind: "text", text: { kind: BlockFormText_Kind.SECRET } },
      },
    ],
    requiredGrant: AgentGrantRequirement.ACCESS,
    closed: false,
  }
  return { text: b.text(), form }
}

describe("bridge v2 forms", () => {
  test("a submission keeps secrets only in the live copy", () => {
    const { form } = approvalForm()
    const result = validateFormSubmission(form, {
      values: [
        { fieldId: "branch", value: { oneofKind: "selection", selection: { optionIds: ["dev"] } }, redacted: false },
        { fieldId: "token", value: { oneofKind: "text", text: "s3cret" }, redacted: false },
      ],
    })
    expect(result.live.values[1]?.value).toEqual({ oneofKind: "text", text: "s3cret" })
    expect(result.stored.values[1]).toEqual({ fieldId: "token", value: { oneofKind: undefined }, redacted: true })
    expect(JSON.stringify(result.stored)).not.toContain("s3cret")
    expect(result.stored.values[0]?.value).toEqual({ oneofKind: "selection", selection: { optionIds: ["dev"] } })
  })

  test("submissions must match the form", () => {
    const { form } = approvalForm()
    const submit = (values: Parameters<typeof validateFormSubmission>[1]["values"]) =>
      () => validateFormSubmission(form, { values })
    // Required field missing.
    expect(submit([])).toThrow()
    // Unknown option, two answers to a single select, wrong kind, unknown field.
    expect(submit([{ fieldId: "branch", value: { oneofKind: "selection", selection: { optionIds: ["x"] } }, redacted: false }])).toThrow()
    expect(submit([{ fieldId: "branch", value: { oneofKind: "selection", selection: { optionIds: ["main"], otherText: "x" } }, redacted: false }])).toThrow()
    expect(submit([{ fieldId: "branch", value: { oneofKind: "text", text: "main" }, redacted: false }])).toThrow()
    expect(submit([{ fieldId: "nope", value: { oneofKind: "toggle", toggle: true }, redacted: false }])).toThrow()
    // "Other" is a valid single answer.
    expect(submit([{ fieldId: "branch", value: { oneofKind: "selection", selection: { optionIds: [], otherText: "feature" } }, redacted: false }])).not.toThrow()
    expect(() => validateFormSubmission({ ...form, closed: true }, { values: [] })).toThrow()
  })

  test("form definitions are validated with the other blocks", () => {
    const { text, form } = approvalForm()
    const content: BlockContent = { blocks: [{ kind: { oneofKind: "form", form } }] }
    expect(() => validateBlockContent(text, content)).not.toThrow()

    const secretDefault: BlockForm = structuredClone(form)
    const token = secretDefault.fields[1]!
    if (token.kind.oneofKind === "text") token.kind.text.defaultValue = "leak"
    expect(() => validateBlockContent(text, { blocks: [{ kind: { oneofKind: "form", form: secretDefault } }] })).toThrow()

    const duplicateField: BlockForm = { ...form, fields: [form.fields[0]!, form.fields[0]!] }
    expect(() => validateBlockContent(text, { blocks: [{ kind: { oneofKind: "form", form: duplicateField } }] })).toThrow()
  })

  test("action IDs cannot shadow a form", () => {
    const { form } = approvalForm()
    const content: BlockContent = { blocks: [{ kind: { oneofKind: "form", form } }] }
    const actions: MessageActions = {
      rows: [{ actions: [{ actionId: "question.1", text: "Go", action: { oneofKind: "callback", callback: { data: new Uint8Array() } }, style: 0, requiredGrant: 0 }] }],
    }
    expect(() => normalizeAndValidateMessageActions(actions, content)).toThrow()
    expect(() => normalizeAndValidateMessageActions(actions)).not.toThrow()
  })
})

describe("bridge v2 blocks", () => {
  test("bot content is validated strictly and gets server directions", () => {
    const b = builder()
    const content: BlockContent = {
      blocks: [
        { kind: { oneofKind: "callout", callout: { kind: 3, title: b.range("Limit reached"), children: [] } } },
        { kind: { oneofKind: "fields", fields: { fields: [{ label: b.range("Command"), value: b.range("cargo test"), monospace: true }] } } },
        { kind: { oneofKind: "steps", steps: { steps: [{ text: b.range("Read the spec"), status: 4 }] } } },
        { kind: { oneofKind: "meter", meter: { label: b.range("Context 62%"), value: 62, max: 100, tone: 0 } } },
        { kind: { oneofKind: "diff", diff: { path: b.range("src/a.rs"), text: b.range("+a"), change: 2 } } },
      ],
    }
    const validated = validateBotBlockContent(b.text(), content)
    expect(validated.blocks).toHaveLength(5)

    const outOfRange: BlockContent = { blocks: [{ kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 10_000n } } }] }
    expect(() => validateBotBlockContent(b.text(), outOfRange)).toThrow()
    const badMeter: BlockContent = { blocks: [{ kind: { oneofKind: "meter", meter: { label: { offset: 0n, length: 1n }, value: 1, max: 0, tone: 0 } } }] }
    expect(() => validateBotBlockContent(b.text(), badMeter)).toThrow()
  })
})

describe("bridge v2 actions and grants", () => {
  test("open_url rejects script and local schemes and keeps app links", () => {
    const action = (url: string): MessageActions => ({
      rows: [{ actions: [{ actionId: "open", text: "Open", action: { oneofKind: "openUrl", openUrl: { url } }, style: MessageAction_Style.PRIMARY, requiredGrant: 0 }] }],
    })
    expect(normalizeAndValidateMessageActions(action("codex://threads/abc"))?.rows[0]?.actions[0]?.style).toBe(MessageAction_Style.PRIMARY)
    expect(() => normalizeAndValidateMessageActions(action("https://inline.chat/x"))).not.toThrow()
    expect(() => normalizeAndValidateMessageActions(action("javascript:alert(1)"))).toThrow()
    expect(() => normalizeAndValidateMessageActions(action("file:///etc/passwd"))).toThrow()
  })

  test("owners always qualify; approvals need the approve grant; questions need any grant", () => {
    const owner: AgentAccess = { botUserId: 1, ownerUserId: 2, isOwner: true, operations: 0 }
    const steerer: AgentAccess = { ...owner, isOwner: false, operations: operationsToMask([AgentGrantOperation.STEER]) }
    const stranger: AgentAccess = { ...owner, isOwner: false, operations: 0 }
    expect(satisfiesGrantRequirement(owner, AgentGrantRequirement.APPROVE)).toBe(true)
    expect(satisfiesGrantRequirement(steerer, AgentGrantRequirement.APPROVE)).toBe(false)
    expect(satisfiesGrantRequirement(steerer, AgentGrantRequirement.ACCESS)).toBe(true)
    expect(satisfiesGrantRequirement(stranger, AgentGrantRequirement.ACCESS)).toBe(false)
    expect(satisfiesGrantRequirement(stranger, AgentGrantRequirement.NONE)).toBe(true)
    expect(satisfiesGrantRequirement(steerer, AgentGrantRequirement.OWNER)).toBe(false)
    expect(satisfiesGrantRequirement(steerer, 99 as AgentGrantRequirement)).toBe(false)
    expect(() => operationsToMask([])).toThrow()
    expect(() => operationsToMask([AgentGrantOperation.UNSPECIFIED])).toThrow()
  })
})

describe("bridge v2 fallbacks for older apps", () => {
  // Shipped apps decode the new kinds as unknown oneof fields. macOS's layout
  // planner then declines the tree and iOS never renders blocks, so both draw
  // Message.message with its entities. That text must therefore hold every
  // block's content.
  test("every new block's text is part of the flat message text", () => {
    const b = builder()
    const { form } = approvalForm()
    const formText = approvalForm().text
    const content: BlockContent = {
      blocks: [
        { kind: { oneofKind: "disclosure", disclosure: { summary: b.range("Ran tests"), kind: 1, activityKind: 8, children: [], status: 4, meta: b.range("48s") } } },
        { kind: { oneofKind: "callout", callout: { kind: 4, title: b.range("Failed"), children: [] } } },
        { kind: { oneofKind: "fields", fields: { fields: [{ label: b.range("Folder"), value: b.range("~/dev/inline"), monospace: true }] } } },
        { kind: { oneofKind: "steps", steps: { steps: [{ text: b.range("Plan"), status: 2, detail: b.range("Planning") }] } } },
        { kind: { oneofKind: "meter", meter: { label: b.range("Usage"), value: 1, max: 2, meta: b.range("50%"), tone: 1 } } },
        { kind: { oneofKind: "diff", diff: { path: b.range("a.rs"), text: b.range("+x"), change: 2, previousPath: b.range("b.rs") } } },
      ],
    }
    const text = b.text()
    const validated = validateBotBlockContent(text, content)
    const covered = JSON.stringify(validated, (_, value) => typeof value === "bigint" ? Number(value) : value)
    const ranges = [...covered.matchAll(/"offset":(\d+),"length":(\d+)/g)].map((match) => text.slice(Number(match[1]), Number(match[1]) + Number(match[2])))
    expect(ranges).toContain("Ran tests")
    expect(ranges).toContain("~/dev/inline")
    for (const range of ranges) expect(text).toContain(range)
    // Form labels and options are in the fallback too, so older apps can answer in text.
    const formRanges = [form.title!, ...form.fields.map((field) => field.label)]
    for (const range of formRanges) {
      expect(formText.slice(Number(range.offset), Number(range.offset + range.length)).length).toBe(Number(range.length))
    }
  })
})
