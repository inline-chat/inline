@testable import InlineIOS
@testable import InlineKit
import InlineProtocol
import Testing
import UIKit

/// Renders each agent card through the real message view and attaches a sheet per
/// appearance, for visual review against the macOS rendering.
@Suite("Agent blocks catalog", .serialized)
@MainActor
struct AgentBlocksCatalogTests {
  /// Message text plus blocks whose ranges point into it.
  private struct Builder {
    var text = ""

    mutating func add(_ string: String) -> BlockText {
      if !text.isEmpty { text += "\n" }
      let start = (text as NSString).length
      text += string
      return .with {
        $0.offset = Int64(start)
        $0.length = Int64((string as NSString).length)
      }
    }
  }

  private static func callback(_ id: String, _ text: String, style: MessageAction.Style = .default) -> MessageAction {
    .with {
      $0.actionID = id
      $0.text = text
      $0.style = style
      $0.callback = .with { $0.data = Data(id.utf8) }
    }
  }

  private static func message(_ id: Int64, _ builder: Builder, _ blocks: [Block], actions: [MessageAction] = []) -> FullMessage {
    var message = NextMessageViewDeviceTests.message(id, builder.text, outgoing: false, reactions: 0)
    message.message.blockContentPayload = BlockContentPayload(.with { $0.blocks = blocks })
    if !actions.isEmpty {
      message.message.actions = .with { $0.rows = [.with { $0.actions = actions }] }
    }
    return message
  }

  static func catalog() -> [(String, FullMessage)] {
    var entries: [(String, FullMessage)] = []

    var plan = Builder()
    let update = plan.add("I found where unknown blocks drop the message. Fixing it now.")
    let steps: [BlockStep] = [
      ("Map current rendering", BlockStatus.done),
      ("Patch the reconciler", .running),
      ("Run InlineKit tests", .pending),
    ].map { text, status in
      let range = plan.add(text)
      return .with { $0.text = range; $0.status = status }
    }
    entries.append(("task list", message(8_001, plan, [
      .with { $0.paragraph = update },
      .with { $0.steps = .with { $0.steps = steps } },
    ])))

    var proposal = Builder()
    var planBlock = BlockPlanProposal()
    planBlock.title = proposal.add("Per-block fallback for rich messages")
    let intro = proposal.add("Keep every message rich when one block can't be drawn.")
    var list = BlockList()
    list.kind = .ordered
    for item in ["Add BlockContentSpan to InlineKit", "Draw the covered text for undrawn kinds", "Enforce span order on the server"] {
      let range = proposal.add(item)
      list.items.append(.with { $0.children = [.with { $0.paragraph = range }] })
    }
    planBlock.children = [.with { $0.paragraph = intro }, .with { $0.list = list }]
    planBlock.state = .pending
    planBlock.actionIds = ["approve", "keep"]
    entries.append(("plan proposal", message(8_002, proposal, [.with { $0.planProposal = planBlock }], actions: [
      callback("approve", "Approve", style: .primary), callback("keep", "Keep planning"),
    ])))

    var approvalText = Builder()
    var approval = BlockApproval()
    approval.subject = .command
    approval.title = approvalText.add("Run a command?")
    approval.command = approvalText.add("swift test --filter BlockContentSpanTests")
    approval.cwd = approvalText.add("apple/InlineKit")
    approval.reason = approvalText.add("Runs the new span tests before the macOS build.")
    approval.state = .pending
    approval.actionIds = ["allow", "deny"]
    entries.append(("approval", message(8_003, approvalText, [.with { $0.approval = approval }], actions: [
      callback("allow", "Approve", style: .primary), callback("deny", "Deny", style: .destructive),
    ])))

    var reviewText = Builder()
    var review = BlockReview()
    review.verdict = .incorrect
    review.summary = reviewText.add("Two issues block merging; one was fixed in this pass.")
    for (title, path, line, priority, outcome) in [
      ("One undrawn block drops the whole message", "apple/InlineIOS/Features/MessageView/MessageRichContent.swift", UInt32(246), BlockReviewFinding.Priority.p0, BlockReviewFinding.Outcome.fixed),
      ("Plan cache ignores action titles", "RichBlockLayoutPlanner.swift", UInt32(173), .p2, .unspecified),
    ] {
      var finding = BlockReviewFinding()
      finding.title = reviewText.add(title)
      finding.path = reviewText.add(path)
      finding.startLine = line
      finding.priority = priority
      finding.outcome = outcome
      review.findings.append(finding)
    }
    entries.append(("review", message(8_004, reviewText, [.with { $0.review = review }])))

    var taskText = Builder()
    var task = BlockTaskSuggestion()
    task.title = taskText.add("Port forms to iOS")
    task.brief = taskText.add("Draw BlockForm on iOS with the macOS controls, option previews and the recommended tag.")
    task.state = .pending
    task.actionIds = ["start", "dismiss"]
    entries.append(("task suggestion", message(8_005, taskText, [.with { $0.taskSuggestion = task }], actions: [
      callback("start", "Start thread", style: .primary), callback("dismiss", "Dismiss"),
    ])))

    var nextText = Builder()
    var next = BlockNextStep()
    next.recap = nextText.add("Per-block fallback is in on iOS and macOS, with tests passing. Nothing is committed.")
    next.question = nextText.add("Commit the fallback fix now?")
    next.blocking = true
    next.actionIds = ["commit", "later"]
    entries.append(("next step", message(8_006, nextText, [.with { $0.nextStep = next }], actions: [
      callback("commit", "Commit", style: .primary), callback("later", "Not yet"),
    ])))

    var promptText = Builder()
    let answer = promptText.add("Pick a follow-up or ask your own.")
    let prompts = ["Fix the P0", "Explain the span rule", "Add tier 2 blocks"].map { label in
      let range = promptText.add(label)
      return BlockPromptSuggestion.with { $0.label = range }
    }
    entries.append(("prompts", message(8_007, promptText, [
      .with { $0.paragraph = answer },
      .with { $0.promptSuggestions = .with { $0.prompts = prompts } },
    ])))

    var formText = Builder()
    var form = BlockForm()
    form.formID = "setup"
    form.title = formText.add("A few questions before I start")
    var auth = BlockFormField()
    auth.fieldID = "auth"
    auth.required = true
    auth.header = formText.add("Auth method")
    auth.label = formText.add("How should people sign in?")
    auth.select = .with { select in
      select.allowOther = true
      select.defaultOptionIds = ["oauth"]
      select.options = [
        .with {
          $0.optionID = "oauth"
          $0.label = formText.add("OAuth with Google and GitHub")
          $0.description_p = formText.add("Fewer passwords to manage.")
          $0.preview = formText.add("[ Continue with Google ]\n[ Continue with GitHub ]")
          $0.recommended = true
        },
        .with {
          $0.optionID = "magic"
          $0.label = formText.add("Email magic link")
          $0.preview = formText.add("Email  [ you@company.com ]\n       [ Send link ]")
        },
      ]
    }
    var notes = BlockFormField()
    notes.fieldID = "notes"
    notes.header = formText.add("Notes")
    notes.label = formText.add("Anything I should avoid?")
    notes.text = .with { $0.kind = .multiline; $0.placeholder = "Optional" }
    form.fields = [auth, notes]
    entries.append(("questionnaire", message(8_009, formText, [.with { $0.form = form }])))

    var unknownText = Builder()
    let before = unknownText.add("Before the new block")
    _ = unknownText.add("This text belongs to a block kind this build doesn't know.")
    let after = unknownText.add("After it, formatting continues normally.")
    let unknown = (try? Block(serializedBytes: [0x9A, 0x06, 0x00] as [UInt8])) ?? Block()
    entries.append(("unknown kind", message(8_008, unknownText, [
      .with { $0.heading = .with { $0.text = before; $0.level = 3 } },
      unknown,
      .with { $0.paragraph = after },
    ])))
    return entries
  }

  @Test("Agent cards render natively", arguments: [UIUserInterfaceStyle.light, .dark])
  func catalog(style: UIUserInterfaceStyle) async throws {
    let stage = try NextMessageViewDeviceTests.Stage(style: style)
    defer { stage.close() }
    let width = stage.window.bounds.width
    stage.root.backgroundColor = style == .dark ? .black : .white
    var rows: [UIImage] = []
    for (index, entry) in Self.catalog().enumerated() {
      let view = MessageView()
      stage.root.addSubview(view)
      var message = entry.1
      message.message.messageId += Int64(index) * 1_000
      let layout = stage.apply(message, to: view, width: width, motion: .immediate)
      #expect(layout.rich != nil, "\(entry.0) fell back to plain text")
      view.frame = CGRect(x: 0, y: 20, width: width, height: layout.size.height)
      view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(200))
      rows.append(UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
      })
      view.removeFromSuperview()
    }
    let height = rows.reduce(0) { $0 + $1.size.height } + 16
    let sheet = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
      (style == .dark ? UIColor.black : UIColor.white).setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      var y: CGFloat = 8
      for row in rows {
        row.draw(at: CGPoint(x: 0, y: y))
        y += row.size.height
      }
    }
    let data = try #require(sheet.pngData())
    Attachment.record(Array(data), named: "agent-blocks-\(style == .dark ? "dark" : "light").png")
    if let directory = ProcessInfo.processInfo.environment["AGENT_BLOCKS_SNAPSHOT_DIR"] {
      try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("ios-agent-blocks-\(style == .dark ? "dark" : "light").png"))
    }
  }
}
