import { describe, expect, test } from "bun:test"
import {
  AgentGrantOperation,
  AgentGrantRequirement,
  BlockApproval_Subject,
  BlockContent as BlockContentCodec,
  BlockDecisionState,
  BlockFormText_Kind,
  BlockReview_Verdict,
  BlockReviewFinding_Confidence,
  BlockReviewFinding_Outcome,
  BlockReviewFinding_Priority,
  MessageAction_Style,
  type Block,
  type BlockContent,
  type BlockForm,
  type BlockText,
  type MessageAction,
  type MessageActions,
} from "@inline-chat/protocol/core"
import { operationsToMask, satisfiesGrantRequirement, type AgentAccess } from "@in/server/modules/agents/grants"
import { blockTextSpan, collectBlockActionIds, validateBlockContent } from "@in/server/modules/message/blockContent"
import { validateBotBlockContent } from "@in/server/modules/message/botBlockContent"
import {
  findCallbackAction,
  normalizeAndValidateMessageActions,
  validateBlockActionReferences,
} from "@in/server/modules/message/messageActions"
import { findForm, validateFormSubmission } from "@in/server/modules/message/messageForms"

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
              { optionId: "main", label: b.range("1. main"), recommended: true },
              { optionId: "dev", label: b.range("2. dev"), recommended: false },
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
    for (const range of formRanges.filter((range) => range !== undefined)) {
      expect(formText.slice(Number(range.offset), Number(range.offset + range.length)).length).toBe(Number(range.length))
    }
  })
})

function callback(actionId: string, text = actionId): MessageAction {
  return { actionId, text, action: { oneofKind: "callback", callback: { data: new Uint8Array() } }, style: 0, requiredGrant: 0 }
}

const agentActions: MessageActions = {
  rows: [
    { actions: [callback("plan.approve", "Approve"), callback("plan.keep", "Keep planning")] },
    { actions: [callback("run.allow", "Allow"), callback("run.deny", "Deny"), callback("fix.1", "Fix")] },
    { actions: [callback("task.start", "Start"), callback("task.dismiss", "Dismiss"), callback("next.yes", "Yes")] },
  ],
}

/** One block of each decision kind over in-order fallback text, buttons named by ID. */
function agentBlocks() {
  const b = builder()
  const plan: Block = {
    kind: {
      oneofKind: "planProposal",
      planProposal: {
        title: b.range("Plan"),
        children: [
          { kind: { oneofKind: "heading", heading: { level: 2, text: b.range("Steps") } } },
          { kind: { oneofKind: "paragraph", paragraph: b.range("Add the column, then backfill.") } },
        ],
        state: BlockDecisionState.PENDING,
        actionIds: ["plan.approve", "plan.keep"],
      },
    },
  }
  const approval: Block = {
    kind: {
      oneofKind: "approval",
      approval: {
        subject: BlockApproval_Subject.COMMAND,
        title: b.range("Run a command?"),
        command: b.range("cargo test --workspace"),
        cwd: b.range("~/dev/inline"),
        reason: b.range("Verify the fix"),
        children: [{ kind: { oneofKind: "diff", diff: { path: b.range("src/a.rs"), text: b.range("+a"), change: 2 } } }],
        state: BlockDecisionState.PENDING,
        actionIds: ["run.allow", "run.deny"],
      },
    },
  }
  const review: Block = {
    kind: {
      oneofKind: "review",
      review: {
        title: b.range("Review"),
        verdict: BlockReview_Verdict.NEEDS_ATTENTION,
        summary: b.range("One issue"),
        findings: [{
          title: b.range("Off-by-one in pagination"),
          body: b.range("The last page is skipped."),
          priority: BlockReviewFinding_Priority.P1,
          path: b.range("src/page.ts"),
          startLine: 10,
          endLine: 12,
          category: "correctness",
          confidence: BlockReviewFinding_Confidence.CONFIRMED,
          outcome: BlockReviewFinding_Outcome.UNSPECIFIED,
          actionId: "fix.1",
        }],
      },
    },
  }
  const task: Block = {
    kind: {
      oneofKind: "taskSuggestion",
      taskSuggestion: {
        title: b.range("Upgrade Bun"),
        brief: b.range("Bump and run the suite"),
        state: BlockDecisionState.ACCEPTED,
        startedPeer: { type: { oneofKind: "chat", chat: { chatId: 42n } } },
        expiresAt: 1_800_000_000n,
        actionIds: ["task.start", "task.dismiss"],
      },
    },
  }
  const next: Block = {
    kind: {
      oneofKind: "nextStep",
      nextStep: { recap: b.range("Fixed the bug; tests pass."), question: b.range("Commit?"), actionIds: ["next.yes"], blocking: true },
    },
  }
  const prompts: Block = {
    kind: {
      oneofKind: "promptSuggestions",
      promptSuggestions: { prompts: [{ label: b.range("Write tests") }, { label: b.range("Explain"), text: "Explain the change in detail" }] },
    },
  }
  return { text: b.text(), blocks: { plan, approval, review, task, next, prompts } }
}

const content = (...blocks: Block[]): BlockContent => ({ blocks })

/** Applies `edit` to a deep copy of the fixture block named `name`. */
function withEdit(name: keyof ReturnType<typeof agentBlocks>["blocks"], edit: (block: Block) => void): { text: string; content: BlockContent } {
  const fixture = agentBlocks()
  const block = structuredClone(fixture.blocks[name])
  edit(block)
  return { text: fixture.text, content: content(block) }
}

const pastEnd: BlockText = { offset: 10_000n, length: 1n }

describe("agent decision blocks", () => {
  test("each kind validates as bot content and names actions the message has", () => {
    const { text, blocks } = agentBlocks()
    for (const block of Object.values(blocks)) {
      expect(() => validateBotBlockContent(text, content(block))).not.toThrow()
    }
    const all = validateBotBlockContent(text, content(...Object.values(blocks)))
    expect(collectBlockActionIds(all.blocks)).toEqual([
      "plan.approve", "plan.keep", "run.allow", "run.deny", "fix.1", "task.start", "task.dismiss", "next.yes",
    ])
    const actions = normalizeAndValidateMessageActions(agentActions, all)
    expect(() => validateBlockActionReferences(all, actions)).not.toThrow()
  })

  test("a range past the text is rejected in every kind", () => {
    const cases = [
      withEdit("plan", (block) => { if (block.kind.oneofKind === "planProposal") block.kind.planProposal.title = pastEnd }),
      withEdit("plan", (block) => {
        if (block.kind.oneofKind === "planProposal") block.kind.planProposal.children.push({ kind: { oneofKind: "paragraph", paragraph: pastEnd } })
      }),
      withEdit("approval", (block) => { if (block.kind.oneofKind === "approval") block.kind.approval.command = pastEnd }),
      withEdit("approval", (block) => {
        if (block.kind.oneofKind === "approval") block.kind.approval.children = [{ kind: { oneofKind: "paragraph", paragraph: pastEnd } }]
      }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.path = pastEnd }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.brief = pastEnd }),
      withEdit("next", (block) => { if (block.kind.oneofKind === "nextStep") block.kind.nextStep.question = pastEnd }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts[0]!.label = pastEnd }),
    ]
    for (const { text, content } of cases) expect(() => validateBotBlockContent(text, content)).toThrow()
  })

  test("required text ranges must be present", () => {
    const cases = [
      withEdit("approval", (block) => { if (block.kind.oneofKind === "approval") delete block.kind.approval.title }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") delete block.kind.review.findings[0]!.title }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") delete block.kind.taskSuggestion.title }),
      withEdit("next", (block) => { if (block.kind.oneofKind === "nextStep") delete block.kind.nextStep.recap }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") delete block.kind.promptSuggestions.prompts[0]!.label }),
      withEdit("plan", (block) => {
        if (block.kind.oneofKind === "planProposal") {
          delete block.kind.planProposal.title
          block.kind.planProposal.children = []
        }
      }),
    ]
    for (const { text, content } of cases) expect(() => validateBotBlockContent(text, content)).toThrow()

    // Present but empty: clients can't draw the block, so it would fall back to its text.
    const empty = { offset: 0n, length: 0n }
    const emptyCases = [
      withEdit("approval", (block) => { if (block.kind.oneofKind === "approval") block.kind.approval.title = empty }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.title = empty }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.title = empty }),
      withEdit("next", (block) => { if (block.kind.oneofKind === "nextStep") block.kind.nextStep.recap = empty }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts[0]!.label = empty }),
    ]
    for (const { text, content } of emptyCases) expect(() => validateBotBlockContent(text, content)).toThrow()
  })

  test("action IDs must be well formed, unique per block and name one of the message's actions", () => {
    const { text, blocks } = agentBlocks()
    const malformed = [
      withEdit("plan", (block) => { if (block.kind.oneofKind === "planProposal") block.kind.planProposal.actionIds = ["has space"] }),
      withEdit("approval", (block) => { if (block.kind.oneofKind === "approval") block.kind.approval.actionIds = ["run.allow", "run.allow"] }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.actionId = "" }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.actionIds = Array.from({ length: 9 }, (_, i) => `a${i}`) }),
      withEdit("next", (block) => { if (block.kind.oneofKind === "nextStep") block.kind.nextStep.actionIds = ["x".repeat(65)] }),
    ]
    for (const { text, content } of malformed) expect(() => validateBotBlockContent(text, content)).toThrow()

    // Well formed but missing from the message's actions, for each kind that names actions.
    const missing = (name: "plan" | "approval" | "task" | "next") => {
      const block = structuredClone(blocks[name])
      switch (block.kind.oneofKind) {
        case "planProposal": block.kind.planProposal.actionIds = ["nope"]; break
        case "approval": block.kind.approval.actionIds = ["nope"]; break
        case "taskSuggestion": block.kind.taskSuggestion.actionIds = ["nope"]; break
        case "nextStep": block.kind.nextStep.actionIds = ["nope"]; break
      }
      return validateBotBlockContent(text, content(block))
    }
    for (const name of ["plan", "approval", "task", "next"] as const) {
      const validated = missing(name)
      expect(() => validateBlockActionReferences(validated, agentActions)).toThrow()
    }
    const finding = validateBotBlockContent(text, withEdit("review", (block) => {
      if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.actionId = "nope"
    }).content)
    expect(() => validateBlockActionReferences(finding, agentActions)).toThrow()
    // No actions at all, and a nested block naming an action.
    expect(() => validateBlockActionReferences(content(blocks.next), undefined)).toThrow()
    const nested = content({ kind: { oneofKind: "callout", callout: { kind: 1, children: [blocks.next] } } })
    expect(collectBlockActionIds(nested.blocks)).toEqual(["next.yes"])
    expect(() => validateBlockActionReferences(nested, { rows: [] })).toThrow()
    // Blocks without buttons need no actions.
    expect(() => validateBlockActionReferences(content(blocks.prompts), undefined)).not.toThrow()
  })

  test("findings, prompts and peers are bounded", () => {
    const bad = [
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.category = "Correctness" }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.category = "a".repeat(41) }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.category = "has space" }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.startLine = 0 }),
      withEdit("review", (block) => {
        if (block.kind.oneofKind === "review") {
          block.kind.review.findings[0]!.startLine = 12
          block.kind.review.findings[0]!.endLine = 10
        }
      }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.priority = 9 as BlockReviewFinding_Priority }),
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.verdict = 9 as BlockReview_Verdict }),
      withEdit("review", (block) => {
        if (block.kind.oneofKind !== "review") return
        const finding = block.kind.review.findings[0]!
        block.kind.review.findings = Array.from({ length: 201 }, () => finding)
      }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts[1]!.text = "x".repeat(4_001) }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts[1]!.text = "   " }),
      withEdit("prompts", (block) => {
        if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts = Array.from({ length: 9 }, () => ({ label: { offset: 0n, length: 1n } }))
      }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts = [] }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.startedPeer = { type: { oneofKind: "chat", chat: { chatId: 0n } } } }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.startedPeer = { type: { oneofKind: undefined } } }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.expiresAt = -1n }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.state = 6 as BlockDecisionState }),
      withEdit("plan", (block) => { if (block.kind.oneofKind === "planProposal") block.kind.planProposal.decidedByUserId = 0n }),
      withEdit("approval", (block) => { if (block.kind.oneofKind === "approval") block.kind.approval.subject = 6 as BlockApproval_Subject }),
    ]
    for (const { text, content } of bad) expect(() => validateBotBlockContent(text, content)).toThrow()

    const ok = [
      withEdit("review", (block) => { if (block.kind.oneofKind === "review") block.kind.review.findings[0]!.category = "error-handling" }),
      withEdit("prompts", (block) => { if (block.kind.oneofKind === "promptSuggestions") block.kind.promptSuggestions.prompts[1]!.text = "x".repeat(4_000) }),
      withEdit("task", (block) => { if (block.kind.oneofKind === "taskSuggestion") block.kind.taskSuggestion.startedPeer = { type: { oneofKind: "user", user: { userId: 7n } } } }),
    ]
    for (const { text, content } of ok) expect(() => validateBotBlockContent(text, content)).not.toThrow()
  })

  test("decision blocks get server directions; commands and paths stay LTR", () => {
    const b = builder()
    const approval: Block = {
      kind: {
        oneofKind: "approval",
        approval: {
          subject: BlockApproval_Subject.COMMAND,
          title: { ...b.range("اجرای دستور؟"), isRtl: false },
          command: { ...b.range("rm -rf build"), isRtl: true },
          children: [],
          state: BlockDecisionState.PENDING,
          actionIds: [],
        },
      },
    }
    const validated = validateBotBlockContent(b.text(), content(approval))
    const kind = validated.blocks[0]!.kind
    expect(kind.oneofKind === "approval" && kind.approval.isRtl).toBe(true)
    expect(kind.oneofKind === "approval" && kind.approval.command?.isRtl).toBeUndefined()
    expect(kind.oneofKind === "approval" && kind.approval.title?.isRtl).toBeUndefined()
  })

  test("forms nested in a plan are found for submission and share the ID namespace", () => {
    const { text: formText, form } = approvalForm()
    const plan: BlockContent = content({
      kind: { oneofKind: "planProposal", planProposal: { children: [{ kind: { oneofKind: "form", form } }], state: 0, actionIds: [] } },
    })
    expect(() => validateBlockContent(formText, plan)).not.toThrow()
    expect(findForm(plan, "question.1")?.formId).toBe("question.1")
    expect(() => normalizeAndValidateMessageActions({ rows: [{ actions: [callback("question.1")] }] }, plan)).toThrow()
  })

  test("stored block content round trips through the wire format", () => {
    const { text, blocks } = agentBlocks()
    const validated = validateBotBlockContent(text, content(...Object.values(blocks)))
    const decoded = BlockContentCodec.fromBinary(BlockContentCodec.toBinary(validated))
    expect(decoded).toEqual(validated)
    expect(() => validateBlockContent(text, decoded, "persisted")).not.toThrow()
  })
})

describe("form extensions", () => {
  test("header and preview are ranges; recommended is carried", () => {
    const b = builder()
    const form: BlockForm = {
      formId: "auth",
      fields: [{
        fieldId: "method",
        header: b.range("Auth method"),
        label: b.range("How should users sign in?"),
        required: true,
        kind: {
          oneofKind: "select",
          select: {
            options: [
              { optionId: "oauth", label: b.range("OAuth"), preview: b.range("GET /oauth/authorize"), recommended: true },
              { optionId: "magic", label: b.range("Magic link"), recommended: false },
            ],
            multiple: false,
            defaultOptionIds: [],
            allowOther: false,
          },
        },
      }],
      requiredGrant: 0,
      closed: false,
    }
    const text = b.text()
    const validated = validateBotBlockContent(text, content({ kind: { oneofKind: "form", form } }))
    const field = validated.blocks[0]!.kind.oneofKind === "form" ? validated.blocks[0]!.kind.form.fields[0] : undefined
    expect(field?.kind.oneofKind === "select" && field.kind.select.options[0]?.recommended).toBe(true)
    expect(blockTextSpan(validated.blocks[0]!)).toEqual({ start: 0, end: text.length - 1 })

    const badHeader = structuredClone(form)
    badHeader.fields[0]!.header = pastEnd
    expect(() => validateBotBlockContent(text, content({ kind: { oneofKind: "form", form: badHeader } }))).toThrow()
    const badPreview = structuredClone(form)
    if (badPreview.fields[0]!.kind.oneofKind === "select") badPreview.fields[0]!.kind.select.options[0]!.preview = pastEnd
    expect(() => validateBotBlockContent(text, content({ kind: { oneofKind: "form", form: badPreview } }))).toThrow()
  })
})

describe("compose action", () => {
  const compose = (text: string): MessageActions => ({
    rows: [{ actions: [{ actionId: "draft", text: "Draft", action: { oneofKind: "compose", compose: { text } }, style: 0, requiredGrant: 0 }] }],
  })

  test("needs non-empty text of at most 4,000 characters", () => {
    expect(normalizeAndValidateMessageActions(compose("  Summarize the thread  "))?.rows[0]?.actions[0]?.action)
      .toEqual({ oneofKind: "compose", compose: { text: "Summarize the thread" } })
    expect(() => normalizeAndValidateMessageActions(compose("x".repeat(4_000)))).not.toThrow()
    expect(() => normalizeAndValidateMessageActions(compose("x".repeat(4_001)))).toThrow()
    expect(() => normalizeAndValidateMessageActions(compose("   "))).toThrow()
    expect(() => normalizeAndValidateMessageActions(compose(""))).toThrow()
  })

  test("is client-side: invoking it never resolves to a bot callback", () => {
    const actions = normalizeAndValidateMessageActions(compose("Summarize"))
    expect(findCallbackAction({ actions, actionId: "draft" })).toBeNull()
  })
})

describe("top-level span order", () => {
  // A client that can't draw a kind newer than itself shows the text between its neighbours.
  test("bot content must cover the text in order without overlap", () => {
    const { text, blocks } = agentBlocks()
    const ordered = Object.values(blocks)
    expect(() => validateBotBlockContent(text, content(...ordered))).not.toThrow()
    expect(() => validateBotBlockContent(text, content(...[...ordered].reverse()))).toThrow()
    expect(() => validateBotBlockContent(text, content(blocks.plan, blocks.plan))).toThrow()
    expect(() => validateBotBlockContent(text, content(blocks.review, blocks.approval))).toThrow()

    // Separators carry no text and sit anywhere; adjacent spans may touch.
    const separator: Block = { kind: { oneofKind: "separator", separator: {} } }
    expect(() => validateBotBlockContent(text, content(separator, blocks.plan, separator, blocks.next))).not.toThrow()
    const touching = "abcde"
    const prompts: Block = { kind: { oneofKind: "promptSuggestions", promptSuggestions: { prompts: [
      { label: { offset: 4n, length: 1n } },
    ] } } }
    expect(() => validateBotBlockContent(touching, content(
      { kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 2n } } },
      { kind: { oneofKind: "paragraph", paragraph: { offset: 2n, length: 2n } } },
      prompts,
    ))).not.toThrow()
    // A child reaching back before an earlier sibling overlaps it too.
    const reachingBack = [
      { kind: { oneofKind: "paragraph", paragraph: { offset: 2n, length: 1n } } },
      { kind: { oneofKind: "callout", callout: { kind: 1, title: { offset: 3n, length: 1n }, children: [
        { kind: { oneofKind: "paragraph", paragraph: { offset: 0n, length: 1n } } },
      ] } } },
    ] satisfies Block[]
    expect(() => validateBotBlockContent(touching, content(...reachingBack, prompts))).toThrow()
    // Content of older kinds only keeps its old freedom: any order is accepted.
    expect(() => validateBotBlockContent(touching, content(...reachingBack))).not.toThrow()
  })

  test("a span covers every range of a block, children included, and skips empty ranges", () => {
    const { blocks } = agentBlocks()
    const plan = blockTextSpan(blocks.plan)
    const approval = blockTextSpan(blocks.approval)
    expect(plan?.start).toBe(0)
    expect(approval && plan && approval.start > plan.end).toBe(true)
    expect(blockTextSpan({ kind: { oneofKind: "separator", separator: {} } })).toBeUndefined()
    expect(blockTextSpan({ kind: { oneofKind: "paragraph", paragraph: { offset: 5n, length: 0n } } })).toBeUndefined()
  })
})
