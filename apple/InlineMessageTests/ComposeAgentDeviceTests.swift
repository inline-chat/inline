@testable import InlineIOS
@testable import InlineKit
@testable import TextProcessing
import AVFAudio
import GRDB
import InlineProtocol
import SwiftUI
import Testing
import UIKit

/// Device lab for the agent compose card. Reads one harness Agent from this
/// device's local data (read-only) and drives the real ComposeView in a
/// window: first-frame layout, growth, bar ⇄ card switching sampled frame by
/// frame, send reset, the outside stop circle, and screenshots.
@Suite("Agent compose lab", .serialized)
@MainActor
struct ComposeAgentDeviceTests {
  @Test("Plain bar keeps its geometry")
  func plainBar() async throws {
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: Self.personID))
    try await settle()
    #expect(!compose.isAgentLayout)
    #expect(compose.plusButton.alpha == 1 && !compose.plusButton.isHidden)
    #expect(compose.agentRowView.isHidden)
    #expect(compose.agentRunButton.isHidden)
    #expect(abs(compose.composeHeightConstraint.constant - ComposeView.minHeight) < 1)
    let capsule = compose.composeAndButtonContainer.frame
    #expect(abs(capsule.minX - (compose.plusButton.frame.maxX + 9.5)) < 1, "capsule \(capsule)")
    #expect(abs(capsule.maxX - (compose.bounds.width - 7)) < 1, "capsule \(capsule)")
    // The hidden stop circle overlaps the mic; taps must still reach it.
    #expect(Self.hits(compose.voiceButton, in: compose), "mic not tappable")
    Attachment.record(host.png(compose), named: "bar.png")
  }

  @Test("Agent DM opens as a card on its first frame")
  func agentDMFirstFrame() async throws {
    let agent = try await Self.agent()
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: agent.id))
    // Read before any wait: the card must not arrive a beat late.
    let firstFrame = (layout: compose.isAgentLayout, height: compose.composeHeightConstraint.constant)
    try await settle()
    Attachment.record(
      "agent \(agent.name) friendly=\(agent.isFriendly)\nfirst frame card=\(firstFrame.layout) height=\(firstFrame.height)\nsettled height=\(compose.composeHeightConstraint.constant) resting=\(compose.restingHeight)\n\(Self.describe(compose))",
      named: "dm-first-frame.txt"
    )
    guard !agent.isFriendly else { return }
    #expect(firstFrame.layout)
    #expect(compose.isAgentLayout)
    #expect(abs(compose.composeHeightConstraint.constant - compose.restingHeight) < 1)
    try Self.expectCardGeometry(compose)
    Attachment.record(host.png(compose), named: "dm-card.png")
  }

  @Test("Typing grows the card upward and keeps the row pinned")
  func typingGrows() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: agent.id))
    try await settle()
    let resting = compose.composeHeightConstraint.constant
    type("Now the Mac sidebar too, and keep the selected row contrast exactly where it is today", into: compose)
    try await settle()
    #expect(compose.composeHeightConstraint.constant > resting + 10)
    try Self.expectCardGeometry(compose)
    #expect(!compose.sendButton.isHidden)
    Attachment.record(host.png(compose), named: "dm-typing.png")
  }

  @Test("A leading mention switches bar ⇄ card without flicker")
  func mentionSwitch() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: Self.personID))
    try await settle()

    // In: a leading agent mention.
    compose.textView.attributedText = Self.mention(agent)
    compose.textViewDidChange(compose.textView)
    let inSamples = try await sample(compose)
    #expect(compose.isAgentLayout)
    try Self.expectCardGeometry(compose)
    Attachment.record(host.png(compose), named: "mention-card.png")

    // Out: the mention is gone.
    compose.textView.attributedText = NSAttributedString(string: "thanks")
    compose.textViewDidChange(compose.textView)
    let outSamples = try await sample(compose)
    #expect(!compose.isAgentLayout)
    #expect(compose.plusButton.alpha == 1)
    #expect(compose.agentRowView.isHidden)

    let report = "in\n" + inSamples.map(\.line).joined(separator: "\n") + "\nout\n" + outSamples.map(\.line).joined(separator: "\n")
    Attachment.record(report, named: "mention-switch-frames.txt")
    #expect(Self.isMonotonic(inSamples.map(\.height), increasing: true), "\(report)")
    #expect(Self.isMonotonic(inSamples.map(\.rowAlpha), increasing: true), "\(report)")
    #expect(Self.isMonotonic(inSamples.map(\.plusAlpha), increasing: false), "\(report)")
    #expect(Self.isMonotonic(outSamples.map(\.height), increasing: false), "\(report)")
    #expect(Self.isMonotonic(outSamples.map(\.rowAlpha), increasing: false), "\(report)")
    #expect(Self.isMonotonic(outSamples.map(\.plusAlpha), increasing: true), "\(report)")

    // Rapid toggling settles on the last state.
    for index in 0 ..< 6 {
      compose.textView.attributedText = index.isMultiple(of: 2) ? Self.mention(agent) : NSAttributedString(string: "x")
      compose.textViewDidChange(compose.textView)
      try await Task.sleep(for: .milliseconds(40))
    }
    try await settle()
    #expect(!compose.isAgentLayout)
    #expect(compose.agentRowView.isHidden && compose.agentRowView.alpha == 0)
    #expect(compose.plusButton.alpha == 1 && !compose.plusButton.isHidden)
  }

  @Test("Sending a mention returns to the bar")
  func sendResets() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: Self.personID))
    try await settle()
    compose.textView.attributedText = Self.mention(agent)
    compose.textViewDidChange(compose.textView)
    try await settle()
    #expect(compose.isAgentLayout)
    compose.resetFullComposeStateAfterTextSend(
      shouldCoordinateSendAnimationReset: true,
      didPrepareSendAnimationPreview: true
    )
    try await settle()
    #expect(!compose.isAgentLayout)
    #expect(abs(compose.composeHeightConstraint.constant - ComposeView.minHeight) < 1)
    #expect(!compose.voiceButton.isHidden)
    #expect(compose.plusButton.alpha == 1)
  }

  @Test("Stop circle beside the bar while a turn runs, hidden inside the card")
  func runCircle() async throws {
    let agent = try await Self.agent()
    let host = try Host()
    defer { host.close() }
    let compose = host.makeCompose(peer: .user(id: Self.personID))
    try await settle()
    let capsuleBefore = compose.composeAndButtonContainer.frame

    compose.agentRunWork = AgentWorkState(
      key: .init(peer: .user(id: Self.personID), botUserID: agent.id),
      sessionID: 1,
      runState: .working
    )
    compose.updateAgentRunCircle(animated: true)
    try await settle()
    #expect(!compose.agentRunButton.isHidden && compose.agentRunButton.alpha > 0.4)
    let capsule = compose.composeAndButtonContainer.frame
    #expect(abs(capsule.maxX - (compose.agentRunButton.frame.minX - 9.5)) < 1, "capsule \(capsule)")
    #expect(abs(compose.agentRunButton.frame.maxX - (compose.bounds.width - 7)) < 1)
    #expect(capsule.width < capsuleBefore.width - 40)
    #expect(Self.hits(compose.voiceButton, in: compose), "mic not tappable beside the stop circle")
    #expect(Self.hits(compose.agentRunButton, in: compose), "stop circle not tappable")
    Attachment.record(host.png(compose), named: "bar-stop.png")

    if !agent.isFriendly {
      compose.textView.attributedText = Self.mention(agent)
      compose.textViewDidChange(compose.textView)
      try await settle()
      #expect(compose.isAgentLayout)
      #expect(compose.agentRunButton.isHidden)
      #expect(abs(compose.composeAndButtonContainer.frame.maxX - (compose.bounds.width - 7)) < 1)
      compose.textView.attributedText = NSAttributedString(string: "")
      compose.textViewDidChange(compose.textView)
      try await settle()
      #expect(!compose.agentRunButton.isHidden)
    }

    compose.agentRunWork = nil
    compose.updateAgentRunCircle(animated: true)
    try await settle()
    #expect(compose.agentRunButton.isHidden)
    #expect(abs(compose.composeAndButtonContainer.frame.maxX - capsuleBefore.maxX) < 1)
  }

  @Test("Review sheet", arguments: [UIUserInterfaceStyle.light, .dark])
  func reviewSheet(style: UIUserInterfaceStyle) async throws {
    let agent = try await Self.agent()
    let host = try Host(style: style)
    defer { host.close() }
    var shots: [UIImage] = []

    let bar = host.makeCompose(peer: .user(id: Self.personID))
    try await settle()
    shots.append(host.snapshot(bar))
    bar.agentRunWork = AgentWorkState(
      key: .init(peer: .user(id: Self.personID), botUserID: agent.id), sessionID: 1, runState: .working
    )
    bar.updateAgentRunCircle(animated: false)
    try await settle()
    shots.append(host.snapshot(bar))
    bar.removeFromSuperview()

    let card = host.makeCompose(peer: .user(id: agent.id))
    try await settle()
    shots.append(host.snapshot(card))
    type("Now the Mac sidebar too, keep the selected row as is", into: card)
    try await settle()
    shots.append(host.snapshot(card))

    let width = shots.map(\.size.width).max() ?? 0
    let height = shots.reduce(0) { $0 + $1.size.height + 12 } + 12
    let sheet = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
      (style == .dark ? UIColor.black : UIColor.systemGroupedBackground).setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      var y: CGFloat = 12
      for shot in shots {
        shot.draw(at: CGPoint(x: 0, y: y))
        y += shot.size.height + 12
      }
    }
    Attachment.record(Array(try #require(sheet.pngData())), named: "agent-compose-\(style == .dark ? "dark" : "light").png")
  }

  @Test("Model and reasoning open native menus")
  func rowMenus() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    let host = try Host()
    defer { host.close() }
    host.window.makeKey()
    let compose = host.makeCompose(peer: .user(id: agent.id))
    try await settle()
    Attachment.record(Self.dumpHierarchy(compose.agentRowView), named: "row-hierarchy.txt")
    let controls = Self.menuControls(in: compose.agentRowView)
    #expect(controls.count >= 2, "menu controls in the row: \(controls.count)")
    var report: [String] = []
    for (index, control) in controls.enumerated() {
      control.performPrimaryAction()
      try await settle()
      report.append("control \(index) ax=\(control.accessibilityLabel ?? "-") menu shown=\(host.showsContextMenu())")
      Attachment.record(host.screenPNG(), named: "row-menu-\(index).png")
      control.contextMenuInteraction?.dismissMenu()
      try await settle()
    }
    Attachment.record(report.joined(separator: "\n"), named: "row-menus.txt")
    #expect(compose.isAgentLayout)
  }

  @Test("Usage opens as a popover above the row")
  func usagePopover() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    let host = try Host()
    defer { host.close() }
    host.window.makeKey()
    let compose = host.makeCompose(peer: .user(id: agent.id))
    try await settle()
    let row = compose.agentRowView.convert(compose.agentRowView.bounds, to: nil)
    compose.presentAgentUsage(from: CGRect(x: row.maxX - 32, y: row.minY, width: 32, height: row.height))
    try await settle()
    let presented = try #require(host.window.rootViewController?.presentedViewController)
    let frame = presented.view.convert(presented.view.bounds, to: nil)
    Attachment.record("popover \(frame) row \(row) controller \(Swift.type(of: presented.presentationController))", named: "usage.txt")
    Attachment.record(host.screenPNG(), named: "usage-popover.png")
    #expect(presented.presentationController is UIPopoverPresentationController)
    // A popover, not an iPhone sheet: narrower than the screen and above the row.
    #expect(frame.width < host.window.bounds.width - 20, "popover \(frame)")
    #expect(frame.maxY <= row.minY + 1, "popover \(frame) row \(row)")
    presented.dismiss(animated: false)
    try await settle()
  }

  @Test("Header folder opens a folder menu", arguments: [UIUserInterfaceStyle.light, .dark])
  func headerFolderMenu(style: UIUserInterfaceStyle) async throws {
    let host = try Host(style: style)
    defer { host.close() }
    host.window.makeKey()
    let folder = ChatAgentFolder(
      title: "inline",
      options: [
        AgentConfigurationOption(id: "inline", label: "inline", description: "~/dev/inline-chat"),
        AgentConfigurationOption(id: "noor", label: "noor", description: "~/dev"),
        AgentConfigurationOption(id: "secret-sauce", label: "secret-sauce", description: "~/dev/inline-chat"),
      ],
      selection: "inline"
    )
    var selected: [String] = []
    let controller = UIHostingController(rootView: VStack(alignment: .leading, spacing: 0) {
      Text("Claude").font(.body).fontWeight(.medium)
      ChatToolbarFolderSubtitle(folder: folder, onSelect: { selected.append($0) })
    }.padding(.horizontal, 16))
    controller.safeAreaRegions = []
    controller.view.backgroundColor = .clear
    controller.view.frame = CGRect(x: 0, y: 120, width: host.root.bounds.width, height: 56)
    host.root.addSubview(controller.view)
    try await settle()
    Attachment.record(Self.dumpHierarchy(controller.view), named: "header-folder-hierarchy-\(style.rawValue).txt")
    let control = try #require(Self.menuControls(in: controller.view).first, "no folder menu control")
    control.performPrimaryAction()
    try await settle()
    Attachment.record("menu shown=\(host.showsContextMenu())", named: "header-folder-\(style.rawValue).txt")
    Attachment.record(host.screenPNG(), named: "header-folder-menu-\(style == .dark ? "dark" : "light").png")
    control.contextMenuInteraction?.dismissMenu()
    try await settle()
    #expect(selected.isEmpty)
  }

  @Test("Voice from the card returns to the card")
  func voiceFromCard() async throws {
    let agent = try await Self.agent()
    guard !agent.isFriendly else { return }
    guard AVAudioApplication.shared.recordPermission == .granted else {
      Attachment.record("skipped: microphone permission \(AVAudioApplication.shared.recordPermission.rawValue)", named: "voice.txt")
      return
    }
    let host = try Host()
    defer { host.close() }
    host.window.makeKey()
    let compose = host.makeCompose(peer: .user(id: agent.id))
    try await settle()
    #expect(compose.isAgentLayout)

    let start = Task { await compose.voiceViewModel.start(peerId: .user(id: agent.id)) }
    for _ in 0 ..< 30 where compose.voiceViewModel.phase != .recording {
      try await Task.sleep(for: .milliseconds(100))
    }
    try await settle()
    let phase = compose.voiceViewModel.phase
    Attachment.record("phase \(phase)\n\(Self.describe(compose))", named: "voice.txt")
    Attachment.record(host.png(compose), named: "voice-recording.png")
    if phase == .recording {
      // Voice takes the whole compose; the card's row and outside plus stay out.
      #expect(!compose.isAgentLayout)
      #expect(compose.agentRowView.isHidden || compose.agentRowView.alpha == 0)
      #expect(!Self.hits(compose.agentRunButton, in: compose))
    }

    compose.voiceViewModel.cancel()
    _ = await start.value
    try await settle()
    #expect(compose.voiceViewModel.phase == .idle)
    #expect(compose.isAgentLayout)
    #expect(abs(compose.composeHeightConstraint.constant - compose.restingHeight) < 1)
    try Self.expectCardGeometry(compose)
    Attachment.record(host.png(compose), named: "voice-after.png")
  }

  // MARK: Helpers

  static func menuControls(in view: UIView) -> [UIControl] {
    var found: [UIControl] = []
    if let control = view as? UIControl, control.showsMenuAsPrimaryAction, !control.isHidden {
      found.append(control)
    }
    for subview in view.subviews { found += menuControls(in: subview) }
    return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
  }

  static func dumpHierarchy(_ view: UIView, depth: Int = 0) -> String {
    var line = String(repeating: "  ", count: depth) + "\(Swift.type(of: view)) \(view.frame)"
    if view.isHidden { line += " hidden" }
    if let control = view as? UIControl { line += " control menuPrimary=\(control.showsMenuAsPrimaryAction)" }
    let interactions = view.interactions.map { "\(Swift.type(of: $0))" }
    if !interactions.isEmpty { line += " interactions=\(interactions)" }
    if let label = view.accessibilityLabel { line += " ax=\(label)" }
    return ([line] + view.subviews.map { dumpHierarchy($0, depth: depth + 1) }).joined(separator: "\n")
  }

  /// Not a real user; a DM peer that is never an Agent.
  static let personID: Int64 = 9_100_917

  struct Agent {
    let id: Int64
    let name: String
    let isFriendly: Bool
  }

  static let agentID: Int64 = 9_200_001

  /// A harness Agent seeded into the test process's own in-memory database
  /// (AppDatabase.shared is never the user's data under tests): a bot user
  /// and its cached configuration catalog, as a bridge publishes them.
  static func agent() async throws -> Agent {
    let catalog = InlineProtocol.AgentConfigurationCatalog.with {
      $0.models = .with {
        $0.options = [
          .with { $0.id = "opus"; $0.label = "Opus 5.5"; $0.reasoningEffortIds = ["low", "medium", "high"]; $0.defaultReasoningEffortID = "high" },
          .with { $0.id = "sonnet"; $0.label = "Sonnet 5.5"; $0.reasoningEffortIds = ["low", "medium", "high"] },
        ]
        $0.defaultModelID = "opus"
      }
      $0.reasoning = .with {
        $0.options = [
          .with { $0.id = "low"; $0.label = "Low" },
          .with { $0.id = "medium"; $0.label = "Medium" },
          .with { $0.id = "high"; $0.label = "High" },
        ]
      }
    }
    let payload = try catalog.serializedData()
    let bot = User(from: InlineProtocol.User.with {
      $0.id = agentID
      $0.firstName = "Claude"
      $0.bot = true
    })
    try await AppDatabase.shared.dbWriter.write { db in
      try bot.save(db)
      try db.execute(
        sql: "INSERT OR REPLACE INTO agentConfigurationCatalog (botUserId, payload, fetchedAt) VALUES (?, ?, ?)",
        arguments: [agentID, payload, Date()]
      )
    }
    #expect(AgentConfigurationCatalogStore.shared.cachedSnapshot(botUserID: agentID)?.models?.count == 2)
    // The draft target resolver reads bots from the memory cache.
    await ObjectCache.shared.ensure(.user(agentID))
    let friendly = AgentWorkStateStore.shared.outputMode(peer: .user(id: agentID), botUserID: agentID) == .friendly
    return Agent(id: agentID, name: "Claude", isFriendly: friendly)
  }

  static func mention(_ agent: Agent) -> NSAttributedString {
    let text = NSMutableAttributedString(string: "@\(agent.name) make the rows lighter")
    let length = ("@" + agent.name as NSString).length
    text.addAttribute(.mentionUserId, value: agent.id, range: NSRange(location: 0, length: length))
    return text
  }

  static func expectCardGeometry(_ compose: ComposeView) throws {
    let row = compose.agentRowView.frame
    let text = compose.textView.frame
    let send = compose.sendButton.frame
    #expect(!compose.agentRowView.isHidden && compose.agentRowView.alpha == 1)
    #expect(compose.plusButton.alpha == 0)
    #expect(text.maxY <= row.minY + 0.5, "text \(text) row \(row)")
    #expect(row.maxX <= send.minX + 0.5, "row \(row) send \(send)")
    #expect(abs(row.midY - send.midY) < 0.5, "row \(row) send \(send)")
    #expect(row.height == ComposeView.agentRowHeight)
  }

  /// A tap at the view's center lands on it or inside it.
  static func hits(_ target: UIView, in compose: ComposeView) -> Bool {
    let point = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: compose)
    guard let hit = compose.hitTest(point, with: nil) else { return false }
    return hit === target || hit.isDescendant(of: target)
  }

  static func describe(_ compose: ComposeView) -> String {
    "capsule \(compose.composeAndButtonContainer.frame)\ntext \(compose.textView.frame)\nrow \(compose.agentRowView.frame) hidden=\(compose.agentRowView.isHidden)\nsend \(compose.sendButton.frame)\nplus alpha \(compose.plusButton.alpha)"
  }

  static func isMonotonic(_ values: [CGFloat], increasing: Bool) -> Bool {
    zip(values, values.dropFirst()).allSatisfy { increasing ? $1 >= $0 - 0.5 : $1 <= $0 + 0.5 }
  }

  struct Sample {
    let height: CGFloat
    let rowAlpha: CGFloat
    let plusAlpha: CGFloat
    var line: String { String(format: "h %.1f row %.2f plus %.2f", height, rowAlpha, plusAlpha) }
  }

  /// Presentation values every frame for 400 ms, as the eye sees them.
  func sample(_ compose: ComposeView) async throws -> [Sample] {
    var samples: [Sample] = []
    for _ in 0 ..< 25 {
      let row = compose.agentRowView.layer.presentation() ?? compose.agentRowView.layer
      let plus = compose.plusButton.layer.presentation() ?? compose.plusButton.layer
      let body = compose.layer.presentation() ?? compose.layer
      samples.append(Sample(
        height: body.bounds.height,
        rowAlpha: compose.agentRowView.isHidden ? 0 : CGFloat(row.opacity),
        plusAlpha: compose.plusButton.isHidden ? 0 : CGFloat(plus.opacity)
      ))
      try await Task.sleep(for: .milliseconds(16))
    }
    return samples
  }

  func settle() async throws {
    try await Task.sleep(for: .milliseconds(450))
  }

  func type(_ text: String, into compose: ComposeView) {
    compose.textView.text = text
    compose.textViewDidChange(compose.textView)
  }

  @MainActor final class Host {
    let window: UIWindow
    let root: UIView

    init(style: UIUserInterfaceStyle = .light) throws {
      let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
      window = UIWindow(windowScene: scene)
      let controller = UIViewController()
      window.rootViewController = controller
      window.overrideUserInterfaceStyle = style
      window.isHidden = false
      root = controller.view
      root.backgroundColor = style == .dark ? .black : .white
    }

    func close() {
      window.rootViewController?.presentedViewController?.dismiss(animated: false)
      window.isHidden = true
    }

    /// Every window of the scene, back to front, so menus and popovers show.
    func screenPNG() -> [UInt8] {
      guard let scene = window.windowScene else { return [] }
      let windows = scene.windows.filter { !$0.isHidden }.sorted { $0.windowLevel < $1.windowLevel }
      let image = UIGraphicsImageRenderer(bounds: scene.coordinateSpace.bounds).image { _ in
        for window in windows {
          window.drawHierarchy(in: window.frame, afterScreenUpdates: true)
        }
      }
      return Array(image.pngData() ?? Data())
    }

    /// Whether a context menu is on screen in any of the scene's windows.
    func showsContextMenu() -> Bool {
      func search(_ view: UIView) -> Bool {
        "\(Swift.type(of: view))".contains("ContextMenu") || view.subviews.contains(where: search)
      }
      return window.windowScene?.windows.contains { !$0.isHidden && search($0) } ?? false
    }

    /// Pinned to the bottom like the chat screen, without drafts or sends.
    func makeCompose(peer: InlineKit.Peer) -> ComposeView {
      let drafts = Drafts()
      let persistence = DraftPersistenceClient(
        registerIntent: { drafts.registerIntent(for: $0, kind: $1) },
        isLatestIntent: { drafts.isLatestIntent($0) },
        update: { _, _, _, _ in true },
        clear: { _, _ in true }
      )
      let compose = ComposeView(
        frame: CGRect(x: 0, y: 0, width: root.bounds.width, height: 100),
        draftManager: DraftManager(debounceDelay: 2, persistence: persistence)
      )
      compose.translatesAutoresizingMaskIntoConstraints = false
      compose.peerId = peer
      compose.chatId = peer.asUserId()
      root.addSubview(compose)
      NSLayoutConstraint.activate([
        compose.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        compose.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        compose.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.bottomAnchor, constant: -8),
      ])
      root.layoutIfNeeded()
      return compose
    }

    func snapshot(_ compose: ComposeView) -> UIImage {
      // Include some room above for growth and a strip of background.
      let rect = compose.frame.insetBy(dx: 0, dy: -12)
      return UIGraphicsImageRenderer(bounds: rect).image { _ in
        root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
      }
    }

    func png(_ compose: ComposeView) -> [UInt8] {
      Array(snapshot(compose).pngData() ?? Data())
    }
  }
}
