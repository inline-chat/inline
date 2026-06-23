#if DEBUG
import AppKit
import GRDB
import InlineKit
import InlineProtocol
import Nuke
import SwiftUI

struct RichMessageBlockTestBookView: View {
  private let samples = RichMessageTestFixtures.samples
  private let style = RichMessageTestBookDiagnostics.style

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        RichBetaGateSummaryView()
        RichDeterministicLayoutGateView(style: style)
        RichLiveRowSmokeView()
        RichStreamingDraftTestCaseView(style: style)
        RichRendererReuseStressTestCaseView(style: style)
        ForEach(samples) { sample in
          RichMessageTestCaseView(sample: sample, style: style)
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minWidth: 760, minHeight: 620)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

private struct RichBetaGateSummaryView: View {
  private let checks = [
    "Confirm the deterministic layout gate reports ok.",
    "Advance both staged fixtures until they report Reuse gate ok.",
    "Use the Cross-block selection and copy fixture until it reports copy gate ok.",
    "Visually inspect tables, RTL, spoilers, links, media, details, thinking, and code copy.",
    "Repeat the same smoke pass in live chat rows with rich text enabled.",
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "checklist.checked")
          .foregroundStyle(.secondary)
        Text("Beta gate checklist")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
          Text("\(index + 1). \(check)")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(12)
    .frame(width: 544, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
  }
}

private struct RichLiveRowSmokeView: View {
  private let items = RichLiveRowSmokeFixtures.items()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "rectangle.stack")
          .foregroundStyle(.secondary)
        Text("Live row smoke")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text("MessageTableCell")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.tertiary)
      }

      Text("Production row cells sized by MessageSizeCalculator. Inspect bubble/minimal rich/plain rows for clipping, attachment mode, and media row fit.")
        .font(.system(size: 12))
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
          VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
            RichLiveRowTableCellView(item: item)
              .frame(width: item.size.width, height: item.size.height)
              .clipped()
              .overlay(
                Rectangle()
                  .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
              )
          }
        }
      }
    }
    .padding(12)
    .frame(width: RichLiveRowSmokeFixtures.tableWidth + 24, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
    )
  }
}

private struct RichLiveRowSmokeItem: Identifiable {
  let id: String
  let title: String
  let message: FullMessage
  let props: MessageViewProps
  let size: CGSize
}

private struct RichLiveRowTableCellView: NSViewRepresentable {
  let item: RichLiveRowSmokeItem

  func makeNSView(context: Context) -> MessageTableCell {
    let cell = MessageTableCell(frame: NSRect(origin: .zero, size: item.size))
    configure(cell)
    return cell
  }

  func updateNSView(_ cell: MessageTableCell, context: Context) {
    configure(cell)
  }

  private func configure(_ cell: MessageTableCell) {
    RichLiveRowSmokeFixtures.withRichFlagEnabled {
      cell.frame = NSRect(origin: .zero, size: item.size)
      cell.configure(with: item.message, props: item.props, animate: false)
      cell.layoutSubtreeIfNeeded()
    }
  }
}

private enum RichLiveRowSmokeFixtures {
  static let tableWidth: CGFloat = 680

  static func items() -> [RichLiveRowSmokeItem] {
    withRichFlagEnabled {
      let peer = InlineKit.Peer.thread(id: 98_760)
      let mediaRichText = sample("media") ?? RichMessageTestFixtures.samples[0].message
      let collapsibleRichText = sample("collapsible") ?? RichMessageTestFixtures.samples[0].message
      let plainText = "Plain fallback row for rich text live-row inspection."

      return [
        makeItem(
          id: "bubble-rich-media",
          title: "Bubble rich media row",
          messageId: 98_761_001,
          stableId: 98_761_001,
          peer: peer,
          richText: mediaRichText,
          plainText: plainText,
          renderStyle: .bubble
        ),
        makeItem(
          id: "bubble-plain",
          title: "Bubble plain fallback row",
          messageId: 98_761_002,
          stableId: 98_761_002,
          peer: peer,
          richText: nil,
          plainText: plainText,
          renderStyle: .bubble
        ),
        makeItem(
          id: "minimal-rich-collapsible",
          title: "Minimal rich collapsible row",
          messageId: 98_761_003,
          stableId: 98_761_003,
          peer: peer,
          richText: collapsibleRichText,
          plainText: plainText,
          renderStyle: .minimal
        ),
        makeItem(
          id: "minimal-plain",
          title: "Minimal plain fallback row",
          messageId: 98_761_004,
          stableId: 98_761_004,
          peer: peer,
          richText: nil,
          plainText: plainText,
          renderStyle: .minimal
        ),
      ]
    }
  }

  @discardableResult
  static func withRichFlagEnabled<T>(_ body: () -> T) -> T {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    defer {
      if let oldRichFlag {
        UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      } else {
        UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      }
    }
    return body()
  }

  private static func sample(_ id: String) -> RichMessage? {
    RichMessageTestFixtures.samples.first(where: { $0.id == id })?.message
  }

  private static func makeItem(
    id: String,
    title: String,
    messageId: Int64,
    stableId: Int64,
    peer: InlineKit.Peer,
    richText: RichMessage?,
    plainText: String,
    renderStyle: MessageRenderStyle
  ) -> RichLiveRowSmokeItem {
    let message = makeFullMessage(
      messageId: messageId,
      stableId: stableId,
      peer: peer,
      richText: richText,
      plainText: plainText
    )
    let input = inputProps(renderStyle: renderStyle)
    let layout = switch renderStyle {
    case .bubble:
      MessageSizeCalculator.shared.calculateBubbleSize(for: message, with: input, tableWidth: tableWidth).3
    case .minimal:
      MessageSizeCalculator.shared.calculateMinimalSize(for: message, with: input, tableWidth: tableWidth).3
    }
    let props = MessageViewProps(
      firstInGroup: input.firstInGroup,
      startsAfterDaySeparator: input.startsAfterDaySeparator,
      isLastMessage: input.isLastMessage,
      isFirstMessage: input.isFirstMessage,
      isRtl: input.isRtl,
      isDM: input.isDM,
      renderStyle: input.renderStyle,
      index: nil,
      translated: input.translated,
      interactionMode: input.interactionMode,
      replyThreadTitle: input.replyThreadTitle,
      layout: layout
    )
    let height = max(44, ceil(layout.totalHeight))
    return RichLiveRowSmokeItem(
      id: id,
      title: title,
      message: message,
      props: props,
      size: CGSize(width: tableWidth, height: height)
    )
  }

  private static func makeFullMessage(
    messageId: Int64,
    stableId: Int64,
    peer: InlineKit.Peer,
    richText: RichMessage?,
    plainText: String
  ) -> FullMessage {
    var message = Message(
      messageId: messageId,
      fromId: 98_760,
      date: Date(timeIntervalSince1970: 1_782_144_000),
      text: richText?.fallbackText ?? plainText,
      peerUserId: peer.asUserId(),
      peerThreadId: peer.asThreadId(),
      chatId: 98_760,
      richText: richText
    )
    message.globalId = stableId

    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private static func inputProps(renderStyle: MessageRenderStyle) -> MessageViewInputProps {
    MessageViewInputProps(
      firstInGroup: true,
      startsAfterDaySeparator: false,
      isLastMessage: true,
      isFirstMessage: true,
      isDM: false,
      isRtl: false,
      translated: false,
      renderStyle: renderStyle,
      interactionMode: .normal,
      replyThreadTitle: nil
    )
  }
}

private struct RichDeterministicLayoutGateView: View {
  let style: RichMessageBlockStyle

  private var report: RichDeterministicLayoutGateReport {
    RichDeterministicLayoutGateReport.make(style: style)
  }

  var body: some View {
    let report = report
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: report.isPassing ? "checkmark.circle" : "exclamationmark.triangle")
          .foregroundStyle(report.isPassing ? Color(nsColor: .secondaryLabelColor) : .red)
        Text("Deterministic layout gate")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        Text(report.summary)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(report.isPassing ? Color(nsColor: .secondaryLabelColor) : .red)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      if report.failures.isEmpty {
        Text("Layout gate ok: precomputed frames cover content width caps, list/checklist insets, quote/divider geometry, per-block RTL, compact media sizing, table viewport/content geometry, wheel routing, code copy placement, and collapsible child placement.")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        VStack(alignment: .leading, spacing: 3) {
          ForEach(report.failures.prefix(6), id: \.self) { failure in
            Text(failure)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
          if report.failures.count > 6 {
            Text("\(report.failures.count - 6) more failures")
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.red)
          }
        }
      }
    }
    .padding(12)
    .frame(width: 544, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: report.isPassing ? .separatorColor : .systemRed), lineWidth: 0.5)
    )
  }
}

struct RichDeterministicLayoutGateReport {
  let checkedLayouts: Int
  let checkedBlocks: Int
  let structuralSummary: String
  let mediaSummary: String
  let codeSummary: String
  let tableWheelBehaviorSummary: String
  let failures: [String]

  var isPassing: Bool { failures.isEmpty }

  var summary: String {
    if isPassing {
      return "layout gate ok, \(checkedLayouts) layouts, \(checkedBlocks) blocks"
    }
    return "\(failures.count) layout issue(s), \(checkedLayouts) layouts"
  }

  static func make(style: RichMessageBlockStyle) -> Self {
    var gate = RichDeterministicLayoutGate(style: style)
    return gate.report()
  }

  var diagnosticText: String {
    var lines = [summary]
    lines.append("generated_at=\(Date().timeIntervalSince1970)")
    lines.append("checked_layouts=\(checkedLayouts)")
    lines.append("checked_blocks=\(checkedBlocks)")
    lines.append("structural_layouts=\(structuralSummary)")
    lines.append("media_sizing=\(mediaSummary)")
    lines.append("code_layouts=\(codeSummary)")
    lines.append("table_wheel_behavior=\(tableWheelBehaviorSummary)")
    lines.append("failure_count=\(failures.count)")
    lines.append(contentsOf: failures.map { "failure=\($0)" })
    return lines.joined(separator: "\n")
  }
}

struct RichRendererGateReport {
  let streamingDiagnostics: RichRendererReuseDiagnostics
  let stressDiagnostics: RichRendererReuseDiagnostics
  let cacheSignatureSummary: String
  let selectionSummary: String
  let selectionHighlightSummary: String
  let dragSelectionSummary: String
  let spoilerSummary: String
  let spoilerClickSummary: String
  let contextMenuSummary: String
  let contextCopySummary: String
  let copyableBlockSummary: String
  let mediaClickSummary: String
  let visualSummary: String
  let failures: [String]

  var isPassing: Bool { failures.isEmpty }

  var summary: String {
    if isPassing {
      return "renderer gate ok"
    }
    return "\(failures.count) renderer issue(s)"
  }

  static func make(style: RichMessageBlockStyle) -> Self {
    var gate = RichRendererGate(style: style)
    return gate.report()
  }

  var diagnosticLines: [String] {
    var lines = [
      "renderer_summary=\(summary)",
      "renderer_failure_count=\(failures.count)",
      "renderer_streaming_reuse=\(streamingDiagnostics.compactSummary)",
      "renderer_stress_reuse=\(stressDiagnostics.compactSummary)",
      "renderer_cache_signatures=\(cacheSignatureSummary)",
      "renderer_selection=\(selectionSummary)",
      "renderer_selection_highlight=\(selectionHighlightSummary)",
      "renderer_drag_selection=\(dragSelectionSummary)",
      "renderer_spoilers=\(spoilerSummary)",
      "renderer_spoiler_clicks=\(spoilerClickSummary)",
      "renderer_context_menus=\(contextMenuSummary)",
      "renderer_context_copy_actions=\(contextCopySummary)",
      "renderer_copyable_blocks=\(copyableBlockSummary)",
      "renderer_media_clicks=\(mediaClickSummary)",
      "renderer_visual_smoke=\(visualSummary)",
    ]
    lines.append(contentsOf: failures.map { "renderer_failure=\($0)" })
    return lines
  }
}

struct RichLiveRowGateReport {
  let checkedCases: Int
  let rowInteractionChecks: Int
  let rowSpoilerChecks: Int
  let tableScrollChecks: Int
  let chromeGeometryChecks: Int
  let mediaScrollChecks: Int
  let stateUpdateChecks: Int
  let draftStreamingChecks: Int
  let actionRowsChecks: Int
  let timeStatusChecks: Int
  let controllerChecks: Int
  let visualSmokeSummary: String
  let visualSmokeChecks: Int
  let failures: [String]

  var isPassing: Bool { failures.isEmpty }

  var summary: String {
    if isPassing {
      return "live row gate ok, \(checkedCases) checks"
    }
    return "\(failures.count) live row issue(s), \(checkedCases) checks"
  }

  @MainActor static func make(style: RichMessageBlockStyle) -> Self {
    var gate = RichLiveRowGate(style: style)
    return gate.report()
  }

  var diagnosticLines: [String] {
    var lines = [
      "live_row_summary=\(summary)",
      "live_row_checked_cases=\(checkedCases)",
      "live_row_interaction_summary=row interaction gate \(failures.isEmpty ? "ok" : "checked"), \(rowInteractionChecks) checks",
      "live_row_spoiler_summary=spoiler interaction gate \(failures.isEmpty ? "ok" : "checked"), \(rowSpoilerChecks) checks",
      "live_row_table_scroll_summary=table scroll gate \(failures.isEmpty ? "ok" : "checked"), \(tableScrollChecks) checks",
      "live_row_chrome_summary=chrome geometry gate \(failures.isEmpty ? "ok" : "checked"), \(chromeGeometryChecks) checks",
      "live_row_media_scroll_summary=media scroll gate \(failures.isEmpty ? "ok" : "checked"), \(mediaScrollChecks) checks",
      "live_row_state_update_summary=state update gate \(failures.isEmpty ? "ok" : "checked"), \(stateUpdateChecks) checks",
      "live_row_draft_streaming_summary=draft streaming gate \(failures.isEmpty ? "ok" : "checked"), \(draftStreamingChecks) checks",
      "live_row_action_rows_summary=action rows gate \(failures.isEmpty ? "ok" : "checked"), \(actionRowsChecks) checks",
      "live_row_time_status_summary=time/status gate \(failures.isEmpty ? "ok" : "checked"), \(timeStatusChecks) checks",
      "live_row_controller_summary=controller gate \(failures.isEmpty ? "ok" : "checked"), \(controllerChecks) checks",
      "live_row_visual_smoke_summary=\(visualSmokeSummary)",
      "live_row_visual_smoke_checks=\(visualSmokeChecks)",
      "live_row_failure_count=\(failures.count)",
    ]
    lines.append(contentsOf: failures.map { "live_row_failure=\($0)" })
    return lines
  }
}

struct RichMessageTestBookGateReport {
  let layout: RichDeterministicLayoutGateReport
  let renderer: RichRendererGateReport
  let liveRow: RichLiveRowGateReport

  var failures: [String] {
    layout.failures.map { "layout: \($0)" }
      + renderer.failures.map { "renderer: \($0)" }
      + liveRow.failures.map { "live_row: \($0)" }
  }

  var isPassing: Bool { failures.isEmpty }

  var summary: String {
    if isPassing {
      return "testbook gate ok, \(layout.checkedLayouts) layouts, \(layout.checkedBlocks) blocks"
    }
    return "\(failures.count) testbook gate issue(s), \(layout.checkedLayouts) layouts"
  }

  @MainActor static func make(style: RichMessageBlockStyle) -> Self {
    RichMessageTestBookGateReport(
      layout: RichDeterministicLayoutGateReport.make(style: style),
      renderer: RichRendererGateReport.make(style: style),
      liveRow: RichLiveRowGateReport.make(style: style)
    )
  }

  var diagnosticText: String {
    var lines = [summary]
    lines.append("generated_at=\(Date().timeIntervalSince1970)")
    lines.append("checked_layouts=\(layout.checkedLayouts)")
    lines.append("checked_blocks=\(layout.checkedBlocks)")
    lines.append("failure_count=\(failures.count)")
    lines.append("layout_summary=\(layout.summary)")
    lines.append("layout_failure_count=\(layout.failures.count)")
    lines.append("structural_layouts=\(layout.structuralSummary)")
    lines.append("media_sizing=\(layout.mediaSummary)")
    lines.append("code_layouts=\(layout.codeSummary)")
    lines.append("table_wheel_behavior=\(layout.tableWheelBehaviorSummary)")
    lines.append(contentsOf: layout.failures.map { "layout_failure=\($0)" })
    lines.append(contentsOf: renderer.diagnosticLines)
    lines.append(contentsOf: liveRow.diagnosticLines)
    return lines.joined(separator: "\n")
  }
}

enum RichMessageTestBookDiagnostics {
  static var style: RichMessageBlockStyle {
    RichMessageBlockStyle.message(
      fontSize: 14,
      primary: .labelColor,
      secondary: .secondaryLabelColor,
      link: .linkColor
    )
  }

  static func deterministicLayoutGateReport() -> RichDeterministicLayoutGateReport {
    RichDeterministicLayoutGateReport.make(style: style)
  }

  @MainActor static func betaGateReport() -> RichMessageTestBookGateReport {
    RichMessageTestBookGateReport.make(style: style)
  }
}

enum RichMessageTestBookLaunchDiagnostics {
  @MainActor private static var isolatedDelegate: RichMessageTestBookIsolatedAppDelegate?

  static func shouldWriteReport(arguments: [String] = CommandLine.arguments) -> Bool {
    argumentValue(for: "--rich-text-testbook-report", in: arguments) != nil
  }

  @discardableResult
  @MainActor static func writeReportIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
    guard let path = argumentValue(for: "--rich-text-testbook-report", in: arguments) else {
      return false
    }

    let report = RichMessageTestBookDiagnostics.betaGateReport()
    do {
      try report.diagnosticText.write(toFile: path, atomically: true, encoding: .utf8)
      return true
    } catch {
      let message = "Failed to write rich text testbook report to \(path): \(error)\n"
      FileHandle.standardError.write(Data(message.utf8))
      return false
    }
  }

  static func shouldWriteSnapshot(arguments: [String] = CommandLine.arguments) -> Bool {
    argumentValue(for: "--rich-text-testbook-snapshot", in: arguments) != nil
  }

  @MainActor
  @discardableResult
  static func writeSnapshotIfRequested(arguments: [String] = CommandLine.arguments) -> Bool {
    guard let path = argumentValue(for: "--rich-text-testbook-snapshot", in: arguments) else {
      return false
    }

    do {
      try RichMessageTestBookSnapshotWriter.write(to: path, style: RichMessageTestBookDiagnostics.style)
      return true
    } catch {
      let message = "Failed to write rich text testbook snapshot to \(path): \(error)\n"
      FileHandle.standardError.write(Data(message.utf8))
      return false
    }
  }

  static func shouldExitAfterArtifacts(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains("--rich-text-testbook-report-only") || arguments.contains("--rich-text-testbook-snapshot-only")
  }

  static func shouldRunIsolatedTestBook(arguments: [String] = CommandLine.arguments) -> Bool {
    arguments.contains("--rich-text-testbook-only")
  }

  @MainActor
  static func runIsolatedTestBook(app: NSApplication) {
    let windowReportPath = argumentValue(for: "--rich-text-testbook-window-report", in: CommandLine.arguments)
    let activeReportPath = argumentValue(for: "--rich-text-testbook-active-report", in: CommandLine.arguments)
    UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
    UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    let delegate = RichMessageTestBookIsolatedAppDelegate(
      windowReportPath: windowReportPath,
      activeReportPath: activeReportPath
    )
    isolatedDelegate = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    DispatchQueue.main.async {
      delegate.showTestBook(app: app, phase: "run-loop-start")
    }
    app.run()
  }

  @MainActor
  fileprivate static func writeActiveInteractionReport(to path: String) {
    do {
      try RichMessageTestBookActiveInteractionDiagnostics.write(
        to: path,
        style: RichMessageTestBookDiagnostics.style
      )
    } catch {
      let message = "Failed to write rich text active interaction report to \(path): \(error)\n"
      FileHandle.standardError.write(Data(message.utf8))
    }
  }

  @MainActor
  fileprivate static func writeWindowReport(to path: String, phase: String) {
    let windows = NSApp.windows
    var lines = [
      "phase=\(phase)",
      "process_id=\(ProcessInfo.processInfo.processIdentifier)",
      "isActive=\(NSApp.isActive)",
      "activationPolicy=\(NSApp.activationPolicy().rawValue)",
      "window_count=\(windows.count)",
      "keyWindow=\(NSApp.keyWindow?.title ?? "nil")",
      "mainWindow=\(NSApp.mainWindow?.title ?? "nil")",
    ]

    for (index, window) in windows.enumerated() {
      let frame = window.frame
      lines.append(
        [
          "window[\(index)].title=\(window.title)",
          "visible=\(window.isVisible)",
          "miniaturized=\(window.isMiniaturized)",
          "key=\(window.isKeyWindow)",
          "main=\(window.isMainWindow)",
          "orderedIndex=\(window.orderedIndex)",
          "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.size.width)),\(Int(frame.size.height))",
        ].joined(separator: " ")
      )
    }

    do {
      let url = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
    } catch {
      let message = "Failed to write rich text testbook window report to \(path): \(error)\n"
      FileHandle.standardError.write(Data(message.utf8))
    }
  }

  @MainActor
  fileprivate static func installIsolatedTestBookMenu(app: NSApplication) {
    let appName = ProcessInfo.processInfo.processName
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
    let appMenu = NSMenu(title: appName)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    appMenu.addItem(
      withTitle: "About \(appName)",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(
      withTitle: "Quit \(appName)",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )

    let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "Window")
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    windowMenu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    windowMenu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )

    app.mainMenu = mainMenu
    app.windowsMenu = windowMenu
  }

  private static func argumentValue(for flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag) else {
      return nil
    }
    let valueIndex = args.index(after: index)
    guard valueIndex < args.endIndex else {
      return nil
    }
    return args[valueIndex]
  }
}

@MainActor
private final class RichMessageTestBookIsolatedAppDelegate: NSObject, NSApplicationDelegate {
  private let windowReportPath: String?
  private let activeReportPath: String?
  private var didShowTestBook = false
  private var didScheduleActiveReport = false

  init(windowReportPath: String?, activeReportPath: String?) {
    self.windowReportPath = windowReportPath
    self.activeReportPath = activeReportPath
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let app = notification.object as? NSApplication else { return }
    showTestBook(app: app, phase: "did-finish-launching")
  }

  func showTestBook(app: NSApplication, phase: String) {
    app.setActivationPolicy(.regular)
    if !didShowTestBook {
      didShowTestBook = true
      RichMessageTestBookLaunchDiagnostics.installIsolatedTestBookMenu(app: app)
      RichMessageTestBookWindowController.show()
      app.unhide(nil)
      app.activate(ignoringOtherApps: true)
    }

    if let windowReportPath {
      RichMessageTestBookLaunchDiagnostics.writeWindowReport(to: windowReportPath, phase: phase)
    }
    guard let activeReportPath, !didScheduleActiveReport else { return }
    didScheduleActiveReport = true
    let shouldTerminate = CommandLine.arguments.contains("--rich-text-testbook-active-report-only")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak app] in
      MainActor.assumeIsolated {
        RichMessageTestBookLaunchDiagnostics.writeActiveInteractionReport(to: activeReportPath)
        if shouldTerminate {
          app?.terminate(nil)
        }
      }
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
    false
  }

  func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
    false
  }
}

@MainActor
private enum RichMessageTestBookSnapshotWriter {
  static func write(to path: String, style: RichMessageBlockStyle) throws {
    let image = try makeImage(style: style)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = image.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }

  private static func makeImage(style: RichMessageBlockStyle) throws -> NSBitmapImageRep {
    seedSnapshotImageCache()

    let cases = [
      RichRendererVisualCase(id: "selection", label: "Selection and Cross-Block Copy", width: 520),
      RichRendererVisualCase(id: "collapsible", label: "Thinking and Details", width: 520),
      RichRendererVisualCase(id: "media", label: "Media and Native Adapters", width: 520),
      RichRendererVisualCase(id: "rtl", label: "RTL and Tables", width: 420),
    ]

    var sections: [RichMessageTestBookSnapshotSection] = []
    for visualCase in cases {
      guard let sample = RichMessageTestFixtures.samples.first(where: { $0.id == visualCase.id }) else {
        continue
      }
      let layout = RichMessageBlockSizeCalculator.layout(
        for: sample.message,
        width: visualCase.width,
        style: style,
        state: .initial
      )
      let view = RichMessageBlockAppKitView(frame: CGRect(origin: .zero, size: layout.size))
      view.translatesAutoresizingMaskIntoConstraints = true
      view.configure(
        richText: sample.message,
        layout: layout,
        style: style,
        state: .initial,
        stateDidChange: nil
      )
      view.layoutSubtreeIfNeeded()
      sections.append(
        RichMessageTestBookSnapshotSection(
          title: visualCase.label,
          view: view,
          size: layout.size
        )
      )
    }

    guard !sections.isEmpty else {
      throw CocoaError(.fileWriteUnknown)
    }

    let padding: CGFloat = 20
    let titleHeight: CGFloat = 24
    let sectionSpacing: CGFloat = 22
    let width = max(760, ceil(sections.map(\.size.width).max() ?? 0) + padding * 2)
    let height = ceil(
      padding
        + sections.reduce(CGFloat.zero) { total, section in
          total + titleHeight + ceil(section.size.height) + sectionSpacing
        }
    )
    let canvas = RichMessageTestBookSnapshotCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    var y = padding
    for section in sections {
      let label = NSTextField(labelWithString: section.title)
      label.font = .systemFont(ofSize: 13, weight: .semibold)
      label.textColor = .secondaryLabelColor
      label.frame = CGRect(x: padding, y: y, width: width - padding * 2, height: titleHeight)
      canvas.addSubview(label)
      y += titleHeight

      let wrapper = RichMessageTestBookSnapshotCanvas(
        frame: CGRect(x: padding, y: y, width: section.size.width, height: section.size.height)
      )
      wrapper.wantsLayer = true
      wrapper.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
      wrapper.layer?.borderColor = NSColor.separatorColor.cgColor
      wrapper.layer?.borderWidth = 0.5
      wrapper.layer?.masksToBounds = true
      section.view.frame = CGRect(origin: .zero, size: section.size)
      wrapper.addSubview(section.view)
      canvas.addSubview(wrapper)
      y += ceil(section.size.height) + sectionSpacing
    }

    let window = NSWindow(
      contentRect: canvas.bounds,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = canvas
    canvas.layoutSubtreeIfNeeded()
    canvas.displayIfNeeded()

    guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    rep.size = canvas.bounds.size
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    return rep
  }

  private static func seedSnapshotImageCache() {
    for seed in seededImageURLs {
      guard let url = URL(string: seed.url) else { continue }
      let request = ImageRequest(url: url)
      let image = debugImage(label: seed.label, size: seed.size)
      ImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: image), for: request, caches: [.memory])
    }
  }

  private static var seededImageURLs: [(url: String, label: String, size: CGSize)] {
    [
      ("https://picsum.photos/seed/inline-selection-media/520/300", "Selection media", CGSize(width: 520, height: 300)),
      ("https://picsum.photos/seed/inline-rich-text/900/520", "Generated landscape", CGSize(width: 900, height: 520)),
      ("https://picsum.photos/seed/inline-embed-poster/640/360", "Embed poster image", CGSize(width: 640, height: 360)),
      ("https://picsum.photos/seed/inline-embed-post-author/160/160", "Embed post author", CGSize(width: 160, height: 160)),
      ("https://picsum.photos/seed/inline-link-preview/640/360", "Link preview image", CGSize(width: 640, height: 360)),
      ("https://picsum.photos/seed/inline-rtl-media/320/220", "RTL image", CGSize(width: 320, height: 220)),
      ("https://picsum.photos/seed/inline-collage-a/420/260", "First image", CGSize(width: 420, height: 260)),
      ("https://picsum.photos/seed/inline-collage-b/420/260", "Second image", CGSize(width: 420, height: 260)),
    ]
  }

  private static func debugImage(label: String, size: CGSize) -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = CGRect(origin: .zero, size: size)
    let colors = debugColors(for: label)
    NSGradient(starting: colors.0, ending: colors.1)?.draw(in: rect, angle: 28)

    NSColor.white.withAlphaComponent(0.18).setStroke()
    let stripe = NSBezierPath()
    for x in stride(from: -size.height, through: size.width, by: 44) {
      stripe.move(to: CGPoint(x: x, y: 0))
      stripe.line(to: CGPoint(x: x + size.height, y: size.height))
    }
    stripe.lineWidth = 9
    stripe.stroke()

    let text = NSString(string: label)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: max(18, min(34, size.width / 14)), weight: .semibold),
      .foregroundColor: NSColor.white,
      .shadow: {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        return shadow
      }(),
    ]
    let textSize = text.size(withAttributes: attributes)
    text.draw(
      at: CGPoint(
        x: max(16, (size.width - textSize.width) / 2),
        y: max(16, (size.height - textSize.height) / 2)
      ),
      withAttributes: attributes
    )
    return image
  }

  private static func debugColors(for label: String) -> (NSColor, NSColor) {
    let scalars = label.unicodeScalars.map(\.value)
    let hash = scalars.reduce(UInt32(0)) { partial, value in
      partial &* 1_664_525 &+ value &+ 1_013_904_223
    }
    let hueA = CGFloat(hash % 360) / 360
    let hueB = CGFloat((hash / 7 + 135) % 360) / 360
    return (
      NSColor(calibratedHue: hueA, saturation: 0.56, brightness: 0.78, alpha: 1),
      NSColor(calibratedHue: hueB, saturation: 0.48, brightness: 0.66, alpha: 1)
    )
  }
}

private struct RichMessageTestBookSnapshotSection {
  let title: String
  let view: NSView
  let size: CGSize
}

private final class RichMessageTestBookSnapshotCanvas: NSView {
  override var isFlipped: Bool { true }
}

@MainActor
private enum RichMessageTestBookActiveInteractionDiagnostics {
  static func write(to path: String, style: RichMessageBlockStyle) throws {
    var failures: [String] = []
    let spoilerSummary = validateSpoilerMouseDown(style: style, failures: &failures)
    let lines = [
      "active_interaction_gate=\(failures.isEmpty ? "ok" : "failed")",
      "process_id=\(ProcessInfo.processInfo.processIdentifier)",
      "isActive=\(NSApp.isActive)",
      "keyWindow=\(NSApp.keyWindow?.title ?? "nil")",
      "active_spoiler_mouse_down=\(spoilerSummary)",
      "active_failure_count=\(failures.count)",
    ] + failures.map { "active_failure=\($0)" }

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
  }

  private static func validateSpoilerMouseDown(
    style: RichMessageBlockStyle,
    failures: inout [String]
  ) -> String {
    guard let spoilerSample = RichMessageTestFixtures.samples.first(where: { $0.id == "spoilers" }) else {
      failures.append("active spoiler mouseDown: spoiler fixture is missing")
      return "spoiler fixture missing"
    }
    guard let linkSample = RichMessageTestFixtures.samples.first(where: { $0.id == "links" }) else {
      failures.append("active spoiler mouseDown: link fixture is missing")
      return "spoiler link fixture missing"
    }

    var hiddenState: RichMessageBlockStateSnapshot?
    let hiddenView = makeRendererView()
    configure(hiddenView, with: spoilerSample.message, width: 520, style: style) { state in
      hiddenState = state
    }
    let hiddenWindow = mountInKeyWindow(hiddenView, title: "Rich Text Active Spoiler")
    let hiddenWasKey = hiddenWindow.isKeyWindow
    let clickedID = hiddenView.debugMouseDownFirstHiddenSpoilerForTestBook()
    let hiddenChanged = hiddenState != nil
    let hiddenRevealed: Bool
    if let clickedID,
       let hiddenState
    {
      let revealedView = makeRendererView()
      configure(revealedView, with: spoilerSample.message, width: 520, style: style, state: hiddenState)
      hiddenRevealed = revealedView.debugSpoilerDiagnosticsForTestBook().revealedSpoilerIDs.contains(clickedID)
    } else {
      hiddenRevealed = false
    }
    hiddenWindow.close()

    var linkState: RichMessageBlockStateSnapshot?
    let linkView = makeRendererView()
    configure(linkView, with: linkSample.message, width: 520, style: style) { state in
      linkState = state
    }
    let linkWindow = mountInKeyWindow(linkView, title: "Rich Text Active Spoiler Link")
    let linkWasKey = linkWindow.isKeyWindow
    let linkClickedID = linkView.debugMouseDownFirstHiddenSpoilerForTestBook(requireLink: true)
    let linkChanged = linkState != nil
    let linkRevealed: Bool
    if let linkClickedID,
       let linkState
    {
      let revealedLinkView = makeRendererView()
      configure(revealedLinkView, with: linkSample.message, width: 520, style: style, state: linkState)
      let revealed = revealedLinkView.debugSpoilerDiagnosticsForTestBook()
      linkRevealed = revealed.revealedSpoilerIDs.contains(linkClickedID) && revealed.revealedLinkRangeCount > 0
    } else {
      linkRevealed = false
    }
    linkWindow.close()

    if clickedID == nil || !hiddenWasKey || !hiddenChanged || !hiddenRevealed {
      failures.append(
        "active spoiler mouseDown: hidden attempted=\(clickedID != nil), key=\(hiddenWasKey), changed=\(hiddenChanged), revealed=\(hiddenRevealed)"
      )
    }
    if linkClickedID == nil || !linkWasKey || !linkChanged || !linkRevealed {
      failures.append(
        "active spoiler mouseDown: hiddenLink attempted=\(linkClickedID != nil), key=\(linkWasKey), changed=\(linkChanged), revealed=\(linkRevealed)"
      )
    }

    return [
      "hidden attempted=\(clickedID != nil)",
      "key=\(hiddenWasKey)",
      "changed=\(hiddenChanged)",
      "revealed=\(hiddenRevealed)",
      "hiddenLink attempted=\(linkClickedID != nil)",
      "key=\(linkWasKey)",
      "changed=\(linkChanged)",
      "revealed=\(linkRevealed)",
    ].joined(separator: ", ")
  }

  private static func makeRendererView() -> RichMessageBlockAppKitView {
    let view = RichMessageBlockAppKitView(frame: CGRect(x: 0, y: 0, width: 520, height: 1))
    view.translatesAutoresizingMaskIntoConstraints = true
    return view
  }

  private static func configure(
    _ view: RichMessageBlockAppKitView,
    with message: RichMessage,
    width: CGFloat,
    style: RichMessageBlockStyle,
    state: RichMessageBlockStateSnapshot = .initial,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)? = nil
  ) {
    let layout = RichMessageBlockSizeCalculator.layout(
      for: message,
      width: width,
      style: style,
      state: state
    )
    view.frame = CGRect(origin: .zero, size: layout.size)
    view.configure(
      richText: message,
      layout: layout,
      style: style,
      state: state,
      stateDidChange: stateDidChange
    )
    view.layoutSubtreeIfNeeded()
  }

  private static func mountInKeyWindow(_ view: RichMessageBlockAppKitView, title: String) -> NSWindow {
    let size = CGSize(width: max(12, ceil(view.frame.width)), height: max(12, ceil(view.frame.height)))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let host = NSView(frame: CGRect(origin: .zero, size: size))
    host.addSubview(view)
    window.title = title
    window.contentView = host
    window.center()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    return window
  }
}

private struct RichRendererGate {
  private let style: RichMessageBlockStyle
  private var failures: [String] = []

  init(style: RichMessageBlockStyle) {
    self.style = style
  }

  mutating func report() -> RichRendererGateReport {
    let streamingDiagnostics = validateStreamingDraftReuse()
    let stressDiagnostics = validateRendererReuseStress()
    let cacheSignatureSummary = validateCacheSignatures()
    let selectionSummary = validateSelectionCopy()
    let selectionHighlightSummary = validateSelectionHighlightVisual()
    let dragSelectionSummary = validateDragSelectionVisual()
    let spoilerSummary = validateSpoilerState()
    let spoilerClickSummary = validateSpoilerClicks()
    let contextMenuSummary = validateContextMenus()
    let contextCopySummary = validateContextCopyActions()
    let copyableBlockSummary = validateCopyableBlockActions()
    let mediaClickSummary = validateMediaClickActions()
    let visualSummary = validateOffscreenVisualSmoke()

    return RichRendererGateReport(
      streamingDiagnostics: streamingDiagnostics,
      stressDiagnostics: stressDiagnostics,
      cacheSignatureSummary: cacheSignatureSummary,
      selectionSummary: selectionSummary,
      selectionHighlightSummary: selectionHighlightSummary,
      dragSelectionSummary: dragSelectionSummary,
      spoilerSummary: spoilerSummary,
      spoilerClickSummary: spoilerClickSummary,
      contextMenuSummary: contextMenuSummary,
      contextCopySummary: contextCopySummary,
      copyableBlockSummary: copyableBlockSummary,
      mediaClickSummary: mediaClickSummary,
      visualSummary: visualSummary,
      failures: failures
    )
  }

  private mutating func validateStreamingDraftReuse() -> RichRendererReuseDiagnostics {
    let diagnostics = rendererDiagnostics(for: RichMessageTestFixtures.streamingDraftStages, width: 520)
    if diagnostics.rootBlocksReused == 0 {
      failures.append("streaming reuse: root blocks were not reused")
    }
    if diagnostics.textViewsReused == 0 && diagnostics.blockSignatureSkips == 0 {
      failures.append("streaming reuse: text leaves were not reused or skipped by signature")
    }
    return diagnostics
  }

  private mutating func validateRendererReuseStress() -> RichRendererReuseDiagnostics {
    let diagnostics = rendererDiagnostics(for: RichMessageTestFixtures.rendererReuseStressStages, width: 520)
    var missing: [String] = []
    if diagnostics.rootBlocksReused == 0 { missing.append("root") }
    if diagnostics.textViewsReused == 0 { missing.append("text") }
    if diagnostics.tableContainersReused == 0 { missing.append("table") }
    if diagnostics.mediaViewsReused == 0 { missing.append("media") }
    if diagnostics.chromeViewsReused == 0 { missing.append("chrome") }
    if !missing.isEmpty {
      failures.append("renderer reuse stress: missing \(missing.joined(separator: ", ")) reuse")
    }
    return diagnostics
  }

  private mutating func validateCacheSignatures() -> String {
    var checks = 0
    func check(_ condition: Bool, _ message: String) {
      checks += 1
      if !condition {
        failures.append("cache signatures: \(message)")
      }
    }

    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    defer {
      if let oldRichFlag {
        UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      } else {
        UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      }
    }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)

    let text = "Cache signature leading edge " + String(repeating: "middle ", count: 24) + "trailing edge."
    let same = makeCacheSignatureMessage(text: text, rev: 1)
    let sameAgain = makeCacheSignatureMessage(text: text, rev: 1)
    let changedRev = makeCacheSignatureMessage(text: text, rev: 2)
    let changedTextEdge = makeCacheSignatureMessage(text: text + " changed", rev: 1)

    let sameSignature = MessageRenderCacheSignature.content(for: same)
    check(
      sameSignature == MessageRenderCacheSignature.content(for: sameAgain),
      "identical messages should have identical content signatures"
    )
    check(
      sameSignature != MessageRenderCacheSignature.content(for: changedRev),
      "message revision should invalidate content signature"
    )
    check(
      sameSignature != MessageRenderCacheSignature.content(for: changedTextEdge),
      "text edge changes should invalidate content signature"
    )

    let entityA = makeTextURLEntities(url: "https://inline.chat/a")
    let entityACopy = makeTextURLEntities(url: "https://inline.chat/a")
    let entityB = makeTextURLEntities(url: "https://inline.chat/b")
    check(
      MessageRenderCacheSignature.entities(for: entityA) == MessageRenderCacheSignature.entities(for: entityACopy),
      "identical entities should have deterministic signatures"
    )
    check(
      MessageRenderCacheSignature.entities(for: entityA) != MessageRenderCacheSignature.entities(for: entityB),
      "entity payload changes should invalidate entity signature"
    )

    let entityMessageA = makeCacheSignatureMessage(text: text, rev: 1, entities: entityA)
    let entityMessageB = makeCacheSignatureMessage(text: text, rev: 1, entities: entityB)
    check(
      MessageRenderCacheSignature.content(for: entityMessageA) != MessageRenderCacheSignature.content(for: entityMessageB),
      "entity payload changes should invalidate content signature"
    )

    let richA = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" })?.message
    let richB = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" })?.message
    if let richA, let richB {
      let richMessageA = makeCacheSignatureMessage(text: text, rev: 1, richText: richA)
      let richMessageB = makeCacheSignatureMessage(text: text, rev: 1, richText: richB)
      let plainMessage = makeCacheSignatureMessage(text: text, rev: 1)
      let richKeyA = CacheAttrs.shared.getKey(richMessageA, renderStyle: .bubble, styleKey: "cache-signature").stringValue
      let richKeyB = CacheAttrs.shared.getKey(richMessageB, renderStyle: .bubble, styleKey: "cache-signature").stringValue
      let plainKey = CacheAttrs.shared.getKey(plainMessage, renderStyle: .bubble, styleKey: "cache-signature").stringValue
      check(richKeyA != richKeyB, "different rich payloads should invalidate attributed cache key")
      check(richKeyA != plainKey, "rich and plain rows should not share attributed cache key")
    } else {
      failures.append("cache signatures: rich fixtures are missing")
    }

    return "cache signatures \(checks) check(s)"
  }

  private func makeCacheSignatureMessage(
    text: String,
    rev: Int64,
    entities: MessageEntities? = nil,
    richText: RichMessage? = nil
  ) -> FullMessage {
    var message = Message(
      messageId: 77_771,
      fromId: 98_760,
      date: Date(timeIntervalSince1970: 1_782_144_000),
      text: text,
      peerUserId: nil,
      peerThreadId: 98_760,
      chatId: 98_760,
      rev: rev,
      entities: entities,
      richText: richText
    )
    message.globalId = 77_771

    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private func makeTextURLEntities(url: String) -> MessageEntities {
    var textURL = MessageEntity.MessageEntityTextUrl()
    textURL.url = url
    var entity = MessageEntity()
    entity.type = .textURL
    entity.offset = 0
    entity.length = 5
    entity.textURL = textURL
    var entities = MessageEntities()
    entities.entities = [entity]
    return entities
  }

  private mutating func validateSelectionCopy() -> String {
    guard let selectionSample = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" }) else {
      failures.append("selection copy: selection fixture is missing")
      return "selection fixture missing"
    }

    let view = makeRendererView()
    configure(view, with: selectionSample.message, width: 520)
    let copy = view.debugSelectAllRichTextCopySnapshotForTestBook()
    let snapshot = RichSelectionPasteboardSnapshot(text: copy.text, hasRTF: copy.hasRTF)
    if !snapshot.isPassing {
      failures.append("selection copy: \(snapshot.summary)")
    }
    return snapshot.summary
  }

  private mutating func validateSelectionHighlightVisual() -> String {
    guard let selectionSample = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" }) else {
      failures.append("selection highlight: selection fixture is missing")
      return "selection fixture missing"
    }

    let layout = RichMessageBlockSizeCalculator.layout(
      for: selectionSample.message,
      width: 520,
      style: style,
      state: .initial
    )
    let width = ceil(layout.size.width)
    let height = ceil(layout.size.height)
    guard width >= 12, height >= 12 else {
      failures.append("selection highlight: layout is too small \(Int(width))x\(Int(height))")
      return "selection highlight layout too small"
    }

    let snapshotHeight = min(height, 2400)
    let snapshotSize = CGSize(width: width, height: snapshotHeight)
    let view = makeRendererView()
    configure(view, with: selectionSample.message, width: 520)
    view.frame = CGRect(origin: .zero, size: layout.size)

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: snapshotSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let host = NSView(frame: CGRect(origin: .zero, size: snapshotSize))
    host.addSubview(view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let snapshotRect = CGRect(origin: .zero, size: snapshotSize)
    guard let before = bitmapSnapshot(of: view, rect: snapshotRect, label: "selection highlight before") else {
      return "selection highlight missing before bitmap"
    }

    view.debugSelectAllRichTextForTestBook()
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let diagnostics = view.debugSelectionDiagnosticsForTestBook()
    guard let after = bitmapSnapshot(of: view, rect: snapshotRect, label: "selection highlight after") else {
      return "\(diagnostics.compactSummary), missing after bitmap"
    }

    let diff = RichRendererVisualSampler.compare(before, after)
    if !diagnostics.isPassing {
      failures.append("selection highlight: expected selected ranges across multiple visible leaves, \(diagnostics.compactSummary)")
    }
    if !diff.isPassing {
      failures.append("selection highlight: expected selected text to change painted output, \(diff.failureSummary)")
    }

    return "\(diagnostics.compactSummary), \(diff.compactSummary)"
  }

  private mutating func validateDragSelectionVisual() -> String {
    guard let selectionSample = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" }) else {
      failures.append("drag selection: selection fixture is missing")
      return "selection fixture missing"
    }

    let layout = RichMessageBlockSizeCalculator.layout(
      for: selectionSample.message,
      width: 520,
      style: style,
      state: .initial
    )
    let width = ceil(layout.size.width)
    let height = ceil(layout.size.height)
    guard width >= 12, height >= 12 else {
      failures.append("drag selection: layout is too small \(Int(width))x\(Int(height))")
      return "drag selection layout too small"
    }

    let snapshotHeight = min(height, 2400)
    let snapshotSize = CGSize(width: width, height: snapshotHeight)
    let view = makeRendererView()
    configure(view, with: selectionSample.message, width: 520)
    view.frame = CGRect(origin: .zero, size: layout.size)

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: snapshotSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let host = NSView(frame: CGRect(origin: .zero, size: snapshotSize))
    host.addSubview(view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let snapshotRect = CGRect(origin: .zero, size: snapshotSize)
    guard let before = bitmapSnapshot(of: view, rect: snapshotRect, label: "drag selection before") else {
      return "drag selection missing before bitmap"
    }

    let didDrag = view.debugDragSelectRichTextForTestBook()
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let diagnostics = view.debugSelectionDiagnosticsForTestBook()
    let selected = view.debugSelectedRichTextForTestBook()
    guard let after = bitmapSnapshot(of: view, rect: snapshotRect, label: "drag selection after") else {
      return "\(diagnostics.partialSummary), missing after bitmap"
    }

    let diff = RichRendererVisualSampler.compare(before, after)
    if !didDrag {
      failures.append("drag selection: synthesized drag did not start")
    }
    if !diagnostics.isPartialPassing {
      failures.append("drag selection: expected partial selected ranges across multiple visible leaves, \(diagnostics.partialSummary)")
    }

    let expectedMarkers = [
      "Table cell text",
      "Nested quote paragraph",
      "Details child paragraph",
      "Thinking child paragraph",
      "Media caption selection",
    ]
    let missingMarkers = expectedMarkers.filter { !selected.contains($0) }
    if !missingMarkers.isEmpty {
      failures.append("drag selection: missing selected marker(s) \(missingMarkers.joined(separator: ", "))")
    }
    if !diff.isPassing {
      failures.append("drag selection: expected drag-selected text to change painted output, \(diff.failureSummary)")
    }

    let markerSummary = missingMarkers.isEmpty ? "markers ok" : "missing \(missingMarkers.joined(separator: ","))"
    return "\(diagnostics.partialSummary), \(markerSummary), \(diff.compactSummary)"
  }

  private mutating func validateSpoilerState() -> String {
    guard let spoilerSample = RichMessageTestFixtures.samples.first(where: { $0.id == "spoilers" }) else {
      failures.append("spoilers: spoiler fixture is missing")
      return "spoiler fixture missing"
    }
    guard let linkSample = RichMessageTestFixtures.samples.first(where: { $0.id == "links" }) else {
      failures.append("spoilers: link fixture is missing")
      return "link fixture missing"
    }

    let hiddenLayout = RichMessageBlockSizeCalculator.layout(
      for: spoilerSample.message,
      width: 520,
      style: style,
      state: .initial
    )
    let hiddenView = makeRendererView()
    configure(hiddenView, with: spoilerSample.message, width: 520, state: .initial)
    let hidden = hiddenView.debugSpoilerDiagnosticsForTestBook()

    if hidden.spoilerRangeCount < 2 {
      failures.append("spoilers: expected at least two hidden spoiler ranges")
    }
    if hidden.hiddenRangeCount != hidden.spoilerRangeCount || hidden.revealedRangeCount != 0 {
      failures.append("spoilers: initial state should hide every spoiler range")
    }
    if hidden.spoilerHitTargetCount != hidden.spoilerRangeCount || hidden.spoilerHitTargetMissCount > 0 {
      failures.append("spoilers: every initial spoiler range should resolve from a rendered hit target")
    }

    guard let revealID = hidden.spoilerIDs.sorted().first else {
      failures.append("spoilers: no spoiler id was assigned")
      return hidden.compactSummary
    }

    let revealedState = RichMessageBlockStateSnapshot(revealedSpoilers: [revealID])
    let revealedLayout = RichMessageBlockSizeCalculator.layout(
      for: spoilerSample.message,
      width: 520,
      style: style,
      state: revealedState
    )
    if abs(hiddenLayout.size.height - revealedLayout.size.height) > 0.5 ||
      abs(hiddenLayout.size.width - revealedLayout.size.width) > 0.5
    {
      failures.append("spoilers: reveal state should not change layout size")
    }

    let revealedView = makeRendererView()
    configure(revealedView, with: spoilerSample.message, width: 520, state: revealedState)
    let revealed = revealedView.debugSpoilerDiagnosticsForTestBook()
    if !revealed.revealedSpoilerIDs.contains(revealID) {
      failures.append("spoilers: revealed state did not reveal the requested spoiler id")
    }
    if revealed.revealedRangeCount != 1 || revealed.hiddenRangeCount != max(0, hidden.spoilerRangeCount - 1) {
      failures.append("spoilers: reveal state should reveal exactly one range and keep the others hidden")
    }
    if revealed.spoilerHitTargetCount != revealed.spoilerRangeCount || revealed.spoilerHitTargetMissCount > 0 {
      failures.append("spoilers: every revealed-state spoiler range should resolve from a rendered hit target")
    }

    let linkHiddenView = makeRendererView()
    configure(linkHiddenView, with: linkSample.message, width: 520, state: .initial)
    let linkHidden = linkHiddenView.debugSpoilerDiagnosticsForTestBook()
    if linkHidden.hiddenLinkRangeCount == 0 {
      failures.append("spoilers: hidden spoiler link should remain tagged as both hidden spoiler and link")
    }
    if linkHidden.spoilerHitTargetCount != linkHidden.spoilerRangeCount || linkHidden.spoilerHitTargetMissCount > 0 {
      failures.append("spoilers: hidden spoiler link should resolve a spoiler hit target")
    }
    if linkHidden.linkHitTargetCount < linkHidden.hiddenLinkRangeCount ||
      linkHidden.hiddenLinkRevealPriorityCount < linkHidden.hiddenLinkRangeCount
    {
      failures.append("spoilers: hidden spoiler link should resolve both spoiler and link at the rendered hit target")
    }

    guard let linkRevealID = linkHidden.hiddenSpoilerIDs.sorted().first else {
      failures.append("spoilers: hidden spoiler link did not expose a spoiler id")
      return "\(hidden.compactSummary); link \(linkHidden.compactSummary)"
    }

    let linkRevealedView = makeRendererView()
    configure(
      linkRevealedView,
      with: linkSample.message,
      width: 520,
      state: RichMessageBlockStateSnapshot(revealedSpoilers: [linkRevealID])
    )
    let linkRevealed = linkRevealedView.debugSpoilerDiagnosticsForTestBook()
    if linkRevealed.revealedLinkRangeCount == 0 {
      failures.append("spoilers: revealed spoiler link should keep its link attribute")
    }
    if linkRevealed.linkHitTargetCount < linkRevealed.revealedLinkRangeCount {
      failures.append("spoilers: revealed spoiler link should resolve a link hit target")
    }

    return "\(hidden.compactSummary); revealed \(revealed.compactSummary); link \(linkHidden.compactSummary) -> \(linkRevealed.compactSummary)"
  }

  private mutating func validateSpoilerClicks() -> String {
    guard let spoilerSample = RichMessageTestFixtures.samples.first(where: { $0.id == "spoilers" }) else {
      failures.append("spoiler clicks: spoiler fixture is missing")
      return "spoiler click fixture missing"
    }
    guard let linkSample = RichMessageTestFixtures.samples.first(where: { $0.id == "links" }) else {
      failures.append("spoiler clicks: link fixture is missing")
      return "spoiler link fixture missing"
    }

    var diagnostics = RichRendererSpoilerClickDiagnostics()

    var clickedState: RichMessageBlockStateSnapshot?
    let hiddenView = makeRendererView()
    configure(hiddenView, with: spoilerSample.message, width: 520) { state in
      clickedState = state
    }
    mountForEntityClick(hiddenView)
    let clickedID = hiddenView.debugClickFirstHiddenSpoilerForTestBook()
    diagnostics.hiddenClickAttempted = clickedID != nil
    diagnostics.hiddenClickChangedState = clickedState != nil
    if let clickedID,
       let clickedState
    {
      let revealedView = makeRendererView()
      configure(revealedView, with: spoilerSample.message, width: 520, state: clickedState)
      diagnostics.hiddenClickRevealed = revealedView.debugSpoilerDiagnosticsForTestBook().revealedSpoilerIDs.contains(clickedID)
    }

    var linkClickedState: RichMessageBlockStateSnapshot?
    let hiddenLinkView = makeRendererView()
    configure(hiddenLinkView, with: linkSample.message, width: 520) { state in
      linkClickedState = state
    }
    mountForEntityClick(hiddenLinkView)
    let linkClickedID = hiddenLinkView.debugClickFirstHiddenSpoilerForTestBook(requireLink: true)
    diagnostics.hiddenLinkClickAttempted = linkClickedID != nil
    diagnostics.hiddenLinkClickChangedState = linkClickedState != nil
    if let linkClickedID,
       let linkClickedState
    {
      let revealedLinkView = makeRendererView()
      configure(revealedLinkView, with: linkSample.message, width: 520, state: linkClickedState)
      let revealed = revealedLinkView.debugSpoilerDiagnosticsForTestBook()
      diagnostics.hiddenLinkClickRevealed = revealed.revealedSpoilerIDs.contains(linkClickedID) &&
        revealed.revealedLinkRangeCount > 0
    }

    if !diagnostics.isPassing {
      failures.append("spoiler clicks: \(diagnostics.compactSummary)")
    }
    return diagnostics.compactSummary
  }

  private mutating func validateContextMenus() -> String {
    var titles = Set<String>()

    if let selectionSample = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" }) {
      titles.formUnion(contextMenuTitles(for: selectionSample.message, width: 520))
    } else {
      failures.append("context menus: selection fixture is missing")
    }

    if let collapsibleSample = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" }) {
      titles.formUnion(contextMenuTitles(for: collapsibleSample.message, width: 520))
    } else {
      failures.append("context menus: collapsible fixture is missing")
    }

    if let mediaSample = RichMessageTestFixtures.samples.first(where: { $0.id == "media" }) {
      titles.formUnion(contextMenuTitles(for: mediaSample.message, width: 520))
    } else {
      failures.append("context menus: media fixture is missing")
    }
    titles.formUnion(contextMenuTitles(for: publicVideoSourceFixture(), width: 520))

    let requiredTitles = [
      "Select All Rich Text",
      "Copy Rich Message Text",
      "Copy Code",
      "Copy Formula",
      "Copy Cell",
      "Open Link",
      "Copy Link",
      "Open Source URL",
    ]
    let missing = requiredTitles.filter { !titles.contains($0) }
    if !missing.isEmpty {
      failures.append("context menus: missing \(missing.joined(separator: ", "))")
    }

    let sorted = titles.sorted()
    let preview = sorted.prefix(12).joined(separator: ", ")
    return "menus \(titles.count) title(s), required \(requiredTitles.count - missing.count)/\(requiredTitles.count), \(preview)"
  }

  private mutating func validateContextCopyActions() -> String {
    var snapshots: [RichContextCopyActionDebugSnapshot] = []

    if let linksSample = RichMessageTestFixtures.samples.first(where: { $0.id == "links" }) {
      let view = makeRendererView()
      configure(view, with: linksSample.message, width: 520)
      snapshots.append(contentsOf: view.debugContextCopyActionSnapshotsForTestBook())
    } else {
      failures.append("context copy actions: links fixture is missing")
    }

    if let collapsibleSample = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" }) {
      let view = makeRendererView()
      configure(view, with: collapsibleSample.message, width: 520)
      snapshots.append(contentsOf: view.debugContextCopyActionSnapshotsForTestBook())
    } else {
      failures.append("context copy actions: collapsible fixture is missing")
    }

    if let mediaSample = RichMessageTestFixtures.samples.first(where: { $0.id == "media" }) {
      seedMediaClickImageCache()
      let view = makeRendererView()
      configure(view, with: mediaSample.message, width: 520)
      snapshots.append(contentsOf: view.debugContextCopyActionSnapshotsForTestBook())
    } else {
      failures.append("context copy actions: media fixture is missing")
    }

    let sourceView = makeRendererView()
    configure(sourceView, with: publicVideoSourceFixture(), width: 520)
    snapshots.append(contentsOf: sourceView.debugContextCopyActionSnapshotsForTestBook())

    let failed = snapshots.filter { !$0.didCopyExpectedText }
    if !failed.isEmpty {
      let titles = failed.map(\.menuTitle).joined(separator: ", ")
      failures.append("context copy actions: unexpected pasteboard payload for \(titles)")
    }

    func hasCopied(_ title: String, _ expected: String) -> Bool {
      snapshots.contains { $0.menuTitle == title && $0.copiedText == expected }
    }

    let required: [(title: String, expected: String, label: String)] = [
      ("Copy Link", "https://inline.chat", "link"),
      ("Copy Cell", "Public/CDN URLs and hydrated internal refs use native adapters", "table cell"),
      ("Copy Media URL", "https://videos.example.com/inline-rich-video.mp4", "media URL"),
    ]
    let missing = required.filter { !hasCopied($0.title, $0.expected) }
    for item in missing {
      failures.append("context copy actions: missing \(item.label) payload for \(item.title)")
    }

    let passed = snapshots.filter(\.didCopyExpectedText).count
    let requiredCount = required.count - missing.count
    let titles = Set(snapshots.map(\.menuTitle)).sorted().joined(separator: ", ")
    return "context copy \(passed)/\(snapshots.count), required \(requiredCount)/\(required.count), \(titles)"
  }

  private mutating func validateCopyableBlockActions() -> String {
    var snapshots: [RichCopyableBlockDebugSnapshot] = []

    if let selectionSample = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" }) {
      let view = makeRendererView()
      configure(view, with: selectionSample.message, width: 520)
      snapshots.append(contentsOf: view.debugCopyableBlockSnapshotsForTestBook())
    } else {
      failures.append("copyable blocks: selection fixture is missing")
    }

    if let collapsibleSample = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" }) {
      let view = makeRendererView()
      configure(view, with: collapsibleSample.message, width: 520)
      snapshots.append(contentsOf: view.debugCopyableBlockSnapshotsForTestBook())
    } else {
      failures.append("copyable blocks: collapsible fixture is missing")
    }

    let code = snapshots.first { $0.menuTitle == "Copy Code" }
    let formula = snapshots.first { $0.menuTitle == "Copy Formula" }
    if code == nil {
      failures.append("copyable blocks: missing Copy Code block")
    }
    if formula == nil {
      failures.append("copyable blocks: missing Copy Formula block")
    }
    if let code, !code.didCopyExpectedText {
      failures.append("copyable blocks: Copy Code wrote unexpected pasteboard text")
    }
    if let formula, !formula.didCopyExpectedText {
      failures.append("copyable blocks: Copy Formula wrote unexpected pasteboard text")
    }
    if let code, !code.copiedText.contains("pasteboard.write(selected.plainText)") {
      failures.append("copyable blocks: Copy Code payload did not include expected code fixture")
    }
    if let code, !code.actionButtonExists {
      failures.append("copyable blocks: Copy Code action button is missing")
    }
    if let code, !code.actionButtonHitTested {
      failures.append("copyable blocks: Copy Code action button is not the primary hit target")
    }
    if let code, !code.didActionButtonCopyExpectedText {
      failures.append("copyable blocks: Copy Code action button wrote unexpected pasteboard text")
    }
    if let formula, formula.copiedText != "E = mc^2" {
      failures.append("copyable blocks: Copy Formula payload did not match expected formula")
    }

    let passed = snapshots.filter(\.didCopyExpectedText).count
    let buttonCount = snapshots.filter(\.actionButtonExists).count
    let buttonHitCount = snapshots.filter { $0.actionButtonExists && $0.actionButtonHitTested }.count
    let buttonCopyCount = snapshots.filter(\.didActionButtonCopyExpectedText).count
    let titles = snapshots.map(\.menuTitle).sorted().joined(separator: ", ")
    return "copyable \(passed)/\(snapshots.count), buttons \(buttonCopyCount)/\(buttonCount), hits \(buttonHitCount)/\(buttonCount), \(titles)"
  }

  private mutating func validateMediaClickActions() -> String {
    guard let mediaSample = RichMessageTestFixtures.samples.first(where: { $0.id == "media" }) else {
      failures.append("media clicks: media fixture is missing")
      return "media fixture missing"
    }

    seedMediaClickImageCache()
    let view = makeRendererView()
    configure(view, with: mediaSample.message, width: 520)
    let mediaSnapshot = view.debugRichMediaClickSnapshotForTestBook()
    var snapshot = mediaSnapshot

    let sourceView = makeRendererView()
    configure(sourceView, with: publicVideoSourceFixture(), width: 520)
    let sourceSnapshot = sourceView.debugRichMediaClickSnapshotForTestBook()
    snapshot.merge(sourceSnapshot)
    let nativePhotoSnapshot = NewPhotoView.debugPrimaryClickSnapshotForTestBook()
    let requiredImagePreviewCount = 6

    if mediaSnapshot.imageMediaViewCount < requiredImagePreviewCount {
      failures.append("media clicks: expected standalone, embed poster, embed-post author, link-preview, and nested collage image media views")
    }
    if mediaSnapshot.previewableImageCount < requiredImagePreviewCount {
      failures.append("media clicks: expected standalone, embed poster, embed-post author, link-preview, and nested collage images to be previewable")
    }
    if mediaSnapshot.imagePrimaryHitTargetCount < mediaSnapshot.imageMediaViewCount {
      failures.append("media clicks: every rich image media view should be the topmost primary hit target")
    }
    if mediaSnapshot.imagePrimaryHitTargetMissCount > 0 {
      failures.append("media clicks: image media center hit target was stolen by an overlay")
    }
    if snapshot.primaryPreviewOnlyCount < snapshot.previewableImageCount {
      failures.append("media clicks: every previewable image primary action should be Quick Look preview")
    }
    if mediaSnapshot.quickLookPreparedImageCount < mediaSnapshot.previewableImageCount {
      failures.append("media clicks: every previewable rich image should prepare a Quick Look item URL")
    }
    if mediaSnapshot.quickLookPrepareFailureCount > 0 {
      failures.append("media clicks: Quick Look item URL preparation failed for previewable rich image media")
    }
    if mediaSnapshot.primaryClickDispatchPreviewCount < mediaSnapshot.previewableImageCount {
      failures.append("media clicks: previewable image primary clicks should dispatch to Quick Look preview")
    }
    if snapshot.primaryClickDispatchSourceOpenCount > 0 {
      failures.append("media clicks: primary click dispatch must not open a source URL")
    }
    if snapshot.primaryClickClosesPreviewPanelCount > 0 {
      failures.append("media clicks: image primary click must present/update Quick Look, not close an already visible preview")
    }
    if snapshot.primarySourceOpenCount > 0 {
      failures.append("media clicks: source URL must not be a primary image click action")
    }
    if snapshot.nonImagePrimaryPreviewCount > 0 {
      failures.append("media clicks: non-image media must not use image Quick Look as the primary action")
    }
    if snapshot.sourceContextMenuActionCount == 0 {
      failures.append("media clicks: expected an explicit source URL context-menu action")
    }
    if sourceSnapshot.nonImageSourceContextMenuActionCount == 0 {
      failures.append("media clicks: expected non-image public media to keep an explicit source URL action")
    }
    if sourceSnapshot.nonImageSourceCopyActionCount == 0 {
      failures.append("media clicks: expected non-image public media to keep an explicit copy URL action")
    }
    if mediaSnapshot.imageSourceContextMenuActionCount > 0 {
      failures.append("media clicks: image media must not expose a source URL open action")
    }
    if mediaSnapshot.imageSourceCopyActionCount > 0 {
      failures.append("media clicks: image media must not expose a source URL copy action")
    }
    if !nativePhotoSnapshot.isPreviewOnly {
      failures.append("media clicks: native photo adapter primary click should stay Quick Look preview only")
    }

    return [
      "imageViews \(snapshot.imageMediaViewCount)",
      "preview \(snapshot.primaryPreviewOnlyCount)/\(snapshot.previewableImageCount)",
      "quickLookPrepared \(snapshot.quickLookPreparedImageCount)/\(snapshot.previewableImageCount)",
      "quickLookPrepareFailures \(snapshot.quickLookPrepareFailureCount)",
      "quickLookPrepareDetails \(snapshot.quickLookPrepareFailureDetails.prefix(8).joined(separator: ","))",
      "clickDispatchPreview \(snapshot.primaryClickDispatchPreviewCount)/\(snapshot.previewableImageCount)",
      "clickDispatchSource \(snapshot.primaryClickDispatchSourceOpenCount)",
      "clickClosesPreview \(snapshot.primaryClickClosesPreviewPanelCount)",
      "sourcePrimary \(snapshot.primarySourceOpenCount)",
      "imageHit \(snapshot.imagePrimaryHitTargetCount)/\(snapshot.imageMediaViewCount)",
      "imageHitMiss \(snapshot.imagePrimaryHitTargetMissCount)",
      "imageHitMissDetails \(snapshot.imagePrimaryHitTargetMissDetails.prefix(8).joined(separator: ","))",
      "imageSourceMenu \(snapshot.imageSourceContextMenuActionCount)",
      "imageSourceCopy \(snapshot.imageSourceCopyActionCount)",
      "nonImagePreview \(snapshot.nonImagePrimaryPreviewCount)",
      "nonImageSource \(snapshot.nonImageSourceContextMenuActionCount)",
      "nonImageCopy \(snapshot.nonImageSourceCopyActionCount)",
      "sourceMenu \(snapshot.sourceContextMenuActionCount)",
      "nativePhotoPreview \(nativePhotoSnapshot.isPreviewOnly ? 1 : 0)/1",
      "media \(snapshot.mediaViewCount)",
    ].joined(separator: ", ")
  }

  private func publicVideoSourceFixture() -> RichMessage {
    var caption = RichText()
    caption.text = "Public video source placeholder."

    var ref = RichMediaRef()
    ref.alt = "Public video source"
    ref.width = 640
    ref.height = 360
    ref.media = .publicURL("https://videos.example.com/inline-rich-video.mp4")

    var video = RichVideoBlock()
    video.media = ref
    video.caption = [caption]
    video.duration = 10

    var block = RichBlock()
    block.blockID = "media.public-video-source"
    block.block = .video(video)

    var message = RichMessage()
    message.version = 1
    message.blocks = [block]
    message.fallbackText = "Public video source placeholder."
    return message
  }

  private func seedMediaClickImageCache() {
    for seed in mediaClickImageSeeds {
      seedMediaClickImageCache(url: seed.url, size: seed.size)
    }
  }

  private var mediaClickImageSeeds: [(url: String, size: CGSize)] {
    [
      ("https://picsum.photos/seed/inline-rich-text/900/520", CGSize(width: 900, height: 520)),
      ("https://picsum.photos/seed/inline-embed-poster/640/360", CGSize(width: 640, height: 360)),
      ("https://picsum.photos/seed/inline-embed-post-author/160/160", CGSize(width: 160, height: 160)),
      ("https://picsum.photos/seed/inline-link-preview/640/360", CGSize(width: 640, height: 360)),
      ("https://picsum.photos/seed/inline-collage-a/420/260", CGSize(width: 420, height: 260)),
      ("https://picsum.photos/seed/inline-collage-b/420/260", CGSize(width: 420, height: 260)),
    ]
  }

  private func seedMediaClickImageCache(url rawURL: String, size: CGSize) {
    guard let url = URL(string: rawURL) else { return }
    let request = ImageRequest(url: url)
    guard ImagePipeline.shared.cache.cachedImage(for: request) == nil else { return }

    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemBlue.withAlphaComponent(0.22).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    NSColor.systemTeal.withAlphaComponent(0.35).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 8
    path.move(to: CGPoint(x: 0, y: size.height * 0.75))
    path.line(to: CGPoint(x: size.width * 0.4, y: size.height * 0.35))
    path.line(to: CGPoint(x: size.width, y: size.height * 0.62))
    path.stroke()
    image.unlockFocus()

    ImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: image), for: request, caches: [.memory])
  }

  private mutating func validateOffscreenVisualSmoke() -> String {
    let cases = [
      RichRendererVisualCase(id: "selection", label: "selection/copy", width: 520),
      RichRendererVisualCase(id: "collapsible", label: "thinking/details", width: 520),
      RichRendererVisualCase(id: "media", label: "media/native adapters", width: 520),
      RichRendererVisualCase(id: "rtl", label: "rtl/table", width: 420),
    ]

    var stats: [RichRendererVisualSnapshotStats] = []
    for visualCase in cases {
      guard let sample = RichMessageTestFixtures.samples.first(where: { $0.id == visualCase.id }) else {
        failures.append("visual smoke: \(visualCase.id) fixture is missing")
        continue
      }
      guard let snapshot = offscreenVisualSnapshot(for: sample.message, visualCase: visualCase) else {
        continue
      }
      stats.append(snapshot)
      if !snapshot.isPassing {
        failures.append("visual smoke: \(snapshot.failureSummary)")
      }
    }

    let passing = stats.filter(\.isPassing).count
    let details = stats.map(\.compactSummary).joined(separator: "; ")
    if details.isEmpty {
      return "visual smoke \(passing)/\(stats.count) snapshot(s)"
    }
    return "visual smoke \(passing)/\(stats.count) snapshot(s), \(details)"
  }

  private mutating func offscreenVisualSnapshot(
    for message: RichMessage,
    visualCase: RichRendererVisualCase
  ) -> RichRendererVisualSnapshotStats? {
    let layout = RichMessageBlockSizeCalculator.layout(
      for: message,
      width: visualCase.width,
      style: style,
      state: .initial
    )
    let width = ceil(layout.size.width)
    let height = ceil(layout.size.height)
    guard width >= 12, height >= 12 else {
      failures.append("visual smoke: \(visualCase.label) layout is too small \(Int(width))x\(Int(height))")
      return nil
    }

    let snapshotHeight = min(height, 2400)
    let snapshotSize = CGSize(width: width, height: snapshotHeight)
    let view = makeRendererView()
    configure(view, with: message, width: visualCase.width)
    view.frame = CGRect(origin: .zero, size: layout.size)

    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: snapshotSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let host = NSView(frame: CGRect(origin: .zero, size: snapshotSize))
    host.addSubview(view)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()

    let snapshotRect = CGRect(origin: .zero, size: snapshotSize)
    guard let rep = bitmapSnapshot(of: view, rect: snapshotRect, label: visualCase.label) else { return nil }

    return RichRendererVisualSnapshotStats(
      label: visualCase.label,
      pixelWidth: rep.pixelsWide,
      pixelHeight: rep.pixelsHigh,
      sample: RichRendererVisualSampler.sample(rep)
    )
  }

  private mutating func bitmapSnapshot(of view: NSView, rect: CGRect, label: String) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
      failures.append("visual smoke: \(label) could not allocate bitmap")
      return nil
    }
    rep.size = rect.size
    view.cacheDisplay(in: rect, to: rep)
    return rep
  }

  private func contextMenuTitles(for message: RichMessage, width: CGFloat) -> Set<String> {
    let view = makeRendererView()
    configure(view, with: message, width: width)
    return Set(view.debugContextMenuTitlesForTestBook())
  }

  private func rendererDiagnostics(for stages: [RichMessage], width: CGFloat) -> RichRendererReuseDiagnostics {
    let view = makeRendererView()
    for message in stages {
      configure(view, with: message, width: width)
    }
    return view.debugReuseDiagnosticsForTestBook()
  }

  private func makeRendererView() -> RichMessageBlockAppKitView {
    let view = RichMessageBlockAppKitView(frame: CGRect(x: 0, y: 0, width: 520, height: 1))
    view.translatesAutoresizingMaskIntoConstraints = true
    return view
  }

  private func configure(
    _ view: RichMessageBlockAppKitView,
    with message: RichMessage,
    width: CGFloat,
    state: RichMessageBlockStateSnapshot = .initial,
    stateDidChange: ((RichMessageBlockStateSnapshot) -> Void)? = nil
  ) {
    let layout = RichMessageBlockSizeCalculator.layout(
      for: message,
      width: width,
      style: style,
      state: state
    )
    view.frame = CGRect(origin: .zero, size: layout.size)
    view.configure(
      richText: message,
      layout: layout,
      style: style,
      state: state,
      stateDidChange: stateDidChange
    )
    view.layoutSubtreeIfNeeded()
  }

  private func mountForEntityClick(_ view: RichMessageBlockAppKitView) {
    let size = CGSize(width: max(12, ceil(view.frame.width)), height: max(12, ceil(view.frame.height)))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let host = NSView(frame: CGRect(origin: .zero, size: size))
    host.addSubview(view)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    host.layoutSubtreeIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
  }
}

private struct RichRendererVisualCase {
  let id: String
  let label: String
  let width: CGFloat
}

private struct RichRendererVisualSnapshotStats {
  let label: String
  let pixelWidth: Int
  let pixelHeight: Int
  let sample: RichRendererVisualSample

  var minChangedSamples: Int {
    max(6, sample.sampleCount / 250)
  }

  var isPassing: Bool {
    pixelWidth >= 12
      && pixelHeight >= 12
      && sample.sampleCount > 0
      && sample.changedSampleCount >= minChangedSamples
      && sample.distinctBucketCount >= 2
  }

  var compactSummary: String {
    "\(label) \(pixelWidth)x\(pixelHeight) changed \(sample.changedSampleCount)/\(sample.sampleCount), buckets \(sample.distinctBucketCount)"
  }

  var failureSummary: String {
    "\(label) painted \(sample.changedSampleCount)/\(sample.sampleCount) changed samples with \(sample.distinctBucketCount) bucket(s), expected >=\(minChangedSamples) changed samples and >=2 buckets"
  }
}

private struct RichRendererVisualSample {
  let sampleCount: Int
  let changedSampleCount: Int
  let distinctBucketCount: Int
}

private struct RichRendererVisualDiff {
  let sampleCount: Int
  let changedSampleCount: Int

  var minChangedSamples: Int {
    max(8, sampleCount / 300)
  }

  var isPassing: Bool {
    sampleCount > 0 && changedSampleCount >= minChangedSamples
  }

  var compactSummary: String {
    "selection paint changed \(changedSampleCount)/\(sampleCount)"
  }

  var failureSummary: String {
    "selection paint changed \(changedSampleCount)/\(sampleCount) samples, expected >=\(minChangedSamples)"
  }
}

private enum RichRendererVisualSampler {
  static func sample(_ rep: NSBitmapImageRep) -> RichRendererVisualSample {
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    guard width > 0, height > 0 else {
      return RichRendererVisualSample(sampleCount: 0, changedSampleCount: 0, distinctBucketCount: 0)
    }

    let stepX = max(1, width / 160)
    let stepY = max(1, height / 160)
    var buckets: [Int: Int] = [:]
    var sampleCount = 0

    for y in stride(from: 0, to: height, by: stepY) {
      for x in stride(from: 0, to: width, by: stepX) {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
          continue
        }
        let bucket = bucket(for: color)
        buckets[bucket, default: 0] += 1
        sampleCount += 1
      }
    }

    let dominantCount = buckets.values.max() ?? 0
    return RichRendererVisualSample(
      sampleCount: sampleCount,
      changedSampleCount: max(0, sampleCount - dominantCount),
      distinctBucketCount: buckets.count
    )
  }

  static func compare(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep) -> RichRendererVisualDiff {
    let width = min(before.pixelsWide, after.pixelsWide)
    let height = min(before.pixelsHigh, after.pixelsHigh)
    guard width > 0, height > 0 else {
      return RichRendererVisualDiff(sampleCount: 0, changedSampleCount: 0)
    }

    let stepX = max(1, width / 160)
    let stepY = max(1, height / 160)
    var sampleCount = 0
    var changedSampleCount = 0

    for y in stride(from: 0, to: height, by: stepY) {
      for x in stride(from: 0, to: width, by: stepX) {
        guard let beforeColor = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
              let afterColor = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        else { continue }

        sampleCount += 1
        if bucket(for: beforeColor) != bucket(for: afterColor) {
          changedSampleCount += 1
        }
      }
    }

    return RichRendererVisualDiff(sampleCount: sampleCount, changedSampleCount: changedSampleCount)
  }

  private static func bucket(for color: NSColor) -> Int {
    guard color.alphaComponent >= 0.02 else {
      return 0
    }

    let red = quantized(color.redComponent)
    let green = quantized(color.greenComponent)
    let blue = quantized(color.blueComponent)
    let alpha = quantized(color.alphaComponent)
    return red << 12 | green << 8 | blue << 4 | alpha
  }

  private static func quantized(_ value: CGFloat) -> Int {
    min(15, max(0, Int((value * 15).rounded())))
  }
}

private struct RichLiveRowVisualCase {
  let label: String
  let richText: RichMessage?
  let renderStyle: MessageRenderStyle
  let expectedRich: Bool
  let tableWidth: CGFloat
}

private struct RichLiveRowGate {
  private let style: RichMessageBlockStyle
  private let calculator = MessageSizeCalculator.shared
  private var checkedCases = 0
  private var rowInteractionChecks = 0
  private var rowSpoilerChecks = 0
  private var tableScrollChecks = 0
  private var chromeGeometryChecks = 0
  private var mediaScrollChecks = 0
  private var stateUpdateChecks = 0
  private var draftStreamingChecks = 0
  private var actionRowsChecks = 0
  private var timeStatusChecks = 0
  private var controllerChecks = 0
  private var visualSmokeChecks = 0
  private var failures: [String] = []

  init(style: RichMessageBlockStyle) {
    self.style = style
  }

  @MainActor mutating func report() -> RichLiveRowGateReport {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    let messageId: Int64 = 98_760_001
    let stableId: Int64 = 98_760_001
    let plainStableId: Int64 = stableId + 1
    let peer = InlineKit.Peer.thread(id: 98_760)
    let draftId = "rich-testbook-live-row-\(stableId)"

    defer {
      clearDraft(draftId: draftId, peer: peer, messageId: messageId)
      calculator.debugClearRichBlockStateAndLayouts(for: stableId)
      calculator.debugClearRichBlockStateAndLayouts(for: plainStableId)
      CacheAttrs.shared.invalidate()
      if let oldRichFlag {
        UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      } else {
        UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      }
    }

    CacheAttrs.shared.invalidate()
    calculator.debugClearRichBlockStateAndLayouts(for: stableId)

    let durableRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" })?.message
      ?? RichMessageTestFixtures.samples[0].message
    let draftRichText = RichMessageTestFixtures.streamingDraftStages.last ?? durableRichText
    let message = makeFullMessage(
      messageId: messageId,
      stableId: stableId,
      peer: peer,
      richText: durableRichText
    )
    let plainMessage = makeFullMessage(
      messageId: messageId + 1,
      stableId: plainStableId,
      peer: peer,
      richText: nil
    )
    let bubbleProps = props(renderStyle: .bubble)
    let minimalProps = props(renderStyle: .minimal)

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(false)
    check(calculator.effectiveRichText(for: message) == nil, "feature flag off should disable effective rich text")
    check(
      calculator.richBlockLayout(for: message, width: 520, style: style, styleKey: "live-row-off") == nil,
      "feature flag off should not produce rich block layout"
    )
    let fallbackBubble = calculator.calculateBubbleSize(for: message, with: bubbleProps, tableWidth: 720)
    check(fallbackBubble.3.text != nil, "fallback live bubble row should still measure text")
    check(
      calculator.debugRichBlockLayoutCacheCount(for: stableId) == 0,
      "feature flag off should not populate rich layout cache"
    )

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    CacheAttrs.shared.invalidate()
    check(
      calculator.effectiveRichText(for: message)?.stableSignature == durableRichText.stableSignature,
      "feature flag on should use durable rich text"
    )

    guard let durableLayout = calculator.richBlockLayout(
      for: message,
      width: 520,
      style: style,
      styleKey: "live-row"
    ) else {
      check(false, "feature flag on should produce rich block layout")
      return RichLiveRowGateReport(
        checkedCases: checkedCases,
        rowInteractionChecks: rowInteractionChecks,
        rowSpoilerChecks: rowSpoilerChecks,
        tableScrollChecks: tableScrollChecks,
        chromeGeometryChecks: chromeGeometryChecks,
        mediaScrollChecks: mediaScrollChecks,
        stateUpdateChecks: stateUpdateChecks,
        draftStreamingChecks: draftStreamingChecks,
        actionRowsChecks: actionRowsChecks,
        timeStatusChecks: timeStatusChecks,
        controllerChecks: controllerChecks,
        visualSmokeSummary: "visual smoke gate not run",
        visualSmokeChecks: visualSmokeChecks,
        failures: failures
      )
    }
    check(durableLayout.size.width <= 520.5, "durable rich layout should respect row text width")
    check(durableLayout.size.height > 0, "durable rich layout should have positive height")
    let firstCacheCount = calculator.debugRichBlockLayoutCacheCount(for: stableId)
    _ = calculator.richBlockLayout(for: message, width: 520, style: style, styleKey: "live-row")
    check(
      calculator.debugRichBlockLayoutCacheCount(for: stableId) == firstCacheCount,
      "repeated live row measurement should reuse cached rich layout"
    )

    calculator.debugClearRichBlockStateAndLayouts(for: stableId)
    let richBubble = calculator.calculateBubbleSize(for: message, with: bubbleProps, tableWidth: 720)
    check(richBubble.3.text != nil, "rich live bubble row should expose a text layout plan")
    check(
      calculator.debugRichBlockLayoutCacheCount(for: stableId) > 0,
      "rich live bubble row measurement should populate precomputed rich layout cache"
    )
    let richMinimal = calculator.calculateMinimalSize(for: message, with: minimalProps, tableWidth: 720)
    check(richMinimal.3.text != nil, "rich live minimal row should expose a text layout plan")
    check((richMinimal.3.text?.size.width ?? 0) <= 700.5, "rich live minimal row should respect max rich width")

    calculator.setRichBlockState(
      RichMessageBlockStateSnapshot(overrides: ["thinking": true, "details": true]),
      for: stableId
    )
    guard let expandedLayout = calculator.richBlockLayout(
      for: message,
      width: 520,
      style: style,
      styleKey: "live-row"
    ) else {
      check(false, "expanded live row state should produce a rich layout")
      return RichLiveRowGateReport(
        checkedCases: checkedCases,
        rowInteractionChecks: rowInteractionChecks,
        rowSpoilerChecks: rowSpoilerChecks,
        tableScrollChecks: tableScrollChecks,
        chromeGeometryChecks: chromeGeometryChecks,
        mediaScrollChecks: mediaScrollChecks,
        stateUpdateChecks: stateUpdateChecks,
        draftStreamingChecks: draftStreamingChecks,
        actionRowsChecks: actionRowsChecks,
        timeStatusChecks: timeStatusChecks,
        controllerChecks: controllerChecks,
        visualSmokeSummary: "visual smoke gate not run",
        visualSmokeChecks: visualSmokeChecks,
        failures: failures
      )
    }
    check(
      expandedLayout.size.height > durableLayout.size.height,
      "expanded live row state should invalidate and grow collapsed rich layout"
    )
    calculator.setRichBlockState(.initial, for: stableId)

    applyDraft(draftId: draftId, peer: peer, messageId: messageId, richText: draftRichText)
    calculator.invalidateRichBlockLayouts(for: stableId)
    check(
      calculator.effectiveRichText(for: message)?.stableSignature == draftRichText.stableSignature,
      "active draft should override durable rich text for live row measurement"
    )
    let draftLayout = calculator.richBlockLayout(
      for: message,
      width: 520,
      style: style,
      styleKey: "live-row-draft"
    )
    check(draftLayout != nil, "active draft should produce a live row rich layout")

    clearDraft(draftId: draftId, peer: peer, messageId: messageId)
    calculator.invalidateRichBlockLayouts(for: stableId)
    check(
      calculator.effectiveRichText(for: message)?.stableSignature == durableRichText.stableSignature,
      "cleared draft should restore durable rich text for live row measurement"
    )

    validateLiveRowChromeGeometry(richMessage: message, peer: peer)
    validateRowViewSlotTransitions(richMessage: message, plainMessage: plainMessage, peer: peer)
    validateRowMountedSpoilerHitTargets(peer: peer)
    validateRichMediaScrollStatePropagation(
      richText: RichMessageTestFixtures.samples.first(where: { $0.id == "media" })?.message ?? durableRichText,
      peer: peer
    )
    validateRichStateUpdateRowRefresh(richText: durableRichText, peer: peer)
    validateRichDraftStreamingRowRefresh(durableRichText: durableRichText, peer: peer)
    validateRichActionRows(richText: durableRichText, peer: peer)
    validateRichTimeStatusMountedRows(richText: durableRichText, peer: peer)
    validateMessageListControllerMount(durableRichText: durableRichText, peer: peer)
    validateMessageListControllerDatabaseMount(durableRichText: durableRichText)
    let visualSmokeSummary = validateLiveRowOffscreenVisualSmoke(durableRichText: durableRichText, peer: peer)

    return RichLiveRowGateReport(
      checkedCases: checkedCases,
      rowInteractionChecks: rowInteractionChecks,
      rowSpoilerChecks: rowSpoilerChecks,
      tableScrollChecks: tableScrollChecks,
      chromeGeometryChecks: chromeGeometryChecks,
      mediaScrollChecks: mediaScrollChecks,
      stateUpdateChecks: stateUpdateChecks,
      draftStreamingChecks: draftStreamingChecks,
      actionRowsChecks: actionRowsChecks,
      timeStatusChecks: timeStatusChecks,
      controllerChecks: controllerChecks,
      visualSmokeSummary: visualSmokeSummary,
      visualSmokeChecks: visualSmokeChecks,
      failures: failures
    )
  }

  private mutating func check(_ condition: Bool, _ message: String) {
    checkedCases += 1
    if !condition {
      failures.append(message)
    }
  }

  private mutating func checkRowInteraction(_ condition: Bool, _ message: String) {
    rowInteractionChecks += 1
    check(condition, message)
  }

  private mutating func checkRowSpoiler(_ condition: Bool, _ message: String) {
    rowSpoilerChecks += 1
    check(condition, message)
  }

  private mutating func checkTableScroll(_ condition: Bool, _ message: String) {
    tableScrollChecks += 1
    check(condition, message)
  }

  private mutating func checkChromeGeometry(_ condition: Bool, _ message: String) {
    chromeGeometryChecks += 1
    check(condition, message)
  }

  private mutating func checkMediaScroll(_ condition: Bool, _ message: String) {
    mediaScrollChecks += 1
    check(condition, message)
  }

  private mutating func checkStateUpdate(_ condition: Bool, _ message: String) {
    stateUpdateChecks += 1
    check(condition, message)
  }

  private mutating func checkDraftStreaming(_ condition: Bool, _ message: String) {
    draftStreamingChecks += 1
    check(condition, message)
  }

  private mutating func checkActionRows(_ condition: Bool, _ message: String) {
    actionRowsChecks += 1
    check(condition, message)
  }

  private mutating func checkTimeStatus(_ condition: Bool, _ message: String) {
    timeStatusChecks += 1
    check(condition, message)
  }

  private mutating func checkController(_ condition: Bool, _ message: String) {
    controllerChecks += 1
    check(condition, message)
  }

  private mutating func checkVisualSmoke(_ condition: Bool, _ message: String) {
    visualSmokeChecks += 1
    check(condition, message)
  }

  private mutating func validateLiveRowChromeGeometry(richMessage: FullMessage, peer: InlineKit.Peer) {
    let reactedMessageId = richMessage.message.messageId + 20
    let reactedStableId = richMessage.id + 20
    let reactedMessage = makeFullMessage(
      messageId: reactedMessageId,
      stableId: reactedStableId,
      peer: peer,
      richText: richMessage.message.richText,
      reactions: reactionFixtures(messageId: reactedMessageId, chatId: richMessage.message.chatId)
    )
    defer {
      calculator.debugClearRichBlockStateAndLayouts(for: reactedStableId)
    }

    for (message, label) in [(richMessage, "plain chrome"), (reactedMessage, "reaction chrome")] {
      for renderStyle in MessageRenderStyle.allCases {
        for tableWidth in [CGFloat(420), CGFloat(720)] {
          let props = viewProps(for: message, renderStyle: renderStyle, tableWidth: tableWidth)
          validateChromeGeometry(
            props.layout,
            renderStyle: renderStyle,
            label: "\(label) \(renderStyle.title.lowercased()) \(Int(tableWidth))"
          )
        }
      }
    }
  }

  private func reactionFixtures(messageId: Int64, chatId: Int64) -> [FullReaction] {
    ["👍", "❤️", "🚀"].enumerated().map { index, emoji in
      FullReaction(
        reaction: Reaction(
          id: 98_780_000 + Int64(index),
          messageId: messageId,
          userId: 98_780 + Int64(index),
          emoji: emoji,
          date: Date(timeIntervalSince1970: 1_782_144_000 + Double(index)),
          chatId: chatId
        )
      )
    }
  }

  private mutating func validateChromeGeometry(
    _ layout: MessageSizeCalculator.LayoutPlans,
    renderStyle: MessageRenderStyle,
    label: String
  ) {
    let bubbleBounds = CGRect(origin: .zero, size: layout.bubble.size)
    checkChromeGeometry(
      isPositiveFinite(layout.bubble.size),
      "\(label) bubble should have a finite measured size"
    )
    checkChromeGeometry(
      layout.bubble.size.height <= layout.wrapper.size.height + 0.5,
      "\(label) bubble should fit inside the measured wrapper height"
    )

    var contentBottomBeforeTime: CGFloat = 0
    if let forwardHeader = layout.forwardHeader {
      let rect = chromeRect(for: forwardHeader, top: forwardHeader.spacing.top)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) forward header")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let reply = layout.reply {
      let rect = chromeRect(for: reply, top: layout.replyContentTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) reply")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let photo = layout.photo {
      let rect = chromeRect(for: photo, top: layout.photoContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) photo")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let video = layout.video {
      let rect = chromeRect(for: video, top: layout.videoContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) video")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let document = layout.document {
      let rect = chromeRect(for: document, top: layout.documentContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) document")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let text = layout.text {
      let rect = chromeRect(for: text, top: layout.textContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) rich text slot")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let attachments = layout.attachments {
      let rect = chromeRect(for: attachments, top: layout.attachmentsContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) attachments")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let replyThreadSummary = layout.replyThreadSummary {
      let rect = chromeRect(for: replyThreadSummary, top: layout.replyThreadSummaryContentViewTop)
      validateChromeRect(rect, in: bubbleBounds, label: "\(label) reply thread summary")
      contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
    }
    if let reactions = layout.reactions {
      let rect = chromeRect(for: reactions, top: layout.reactionsViewTop)
      if layout.reactionsOutsideBubble {
        let externalBottom = layout.bubble.size.height
          + layout.reactionsOutsideBubbleTopInset
          + reactions.size.height
          + reactions.spacing.bottom
        checkChromeGeometry(
          externalBottom <= layout.wrapper.size.height + 0.5,
          "\(label) outside reactions should fit inside the measured wrapper"
        )
      } else {
        validateChromeRect(rect, in: bubbleBounds, label: "\(label) reactions")
        if !layout.placesTimeAboveReactions {
          contentBottomBeforeTime = max(contentBottomBeforeTime, rect.maxY)
        }
      }
    }

    guard let time = layout.time else { return }
    checkChromeGeometry(
      isPositiveFinite(time.size),
      "\(label) time/status should have a finite measured size"
    )
    guard layout.timeInContentFlow else { return }

    let timeRect = chromeTimeRect(for: layout, time: time)
    validateChromeRect(timeRect, in: bubbleBounds, label: "\(label) time/status")
    if layout.singleLine, let text = layout.text {
      let textRect = chromeRect(for: text, top: layout.textContentViewTop)
      checkChromeGeometry(
        textRect.maxX <= timeRect.minX + 0.5,
        "\(label) single-line text should not overlap the time/status slot"
      )
    } else {
      checkChromeGeometry(
        contentBottomBeforeTime <= timeRect.minY + 0.5,
        "\(label) multiline content should end before the time/status slot"
      )
    }

    if renderStyle == .bubble {
      checkChromeGeometry(
        timeRect.maxY <= layout.bubble.size.height + 0.5,
        "\(label) time/status should fit inside bubble height"
      )
    }
  }

  private func makeFullMessage(
    messageId: Int64,
    stableId: Int64,
    peer: InlineKit.Peer,
    richText: RichMessage?,
    reactions: [FullReaction] = [],
    actions: MessageActions? = nil
  ) -> FullMessage {
    var message = Message(
      messageId: messageId,
      fromId: 98_760,
      date: Date(timeIntervalSince1970: 1_782_144_000),
      text: richText?.fallbackText ?? "Plain fallback row for rich text live-row reuse.",
      peerUserId: peer.asUserId(),
      peerThreadId: peer.asThreadId(),
      chatId: 98_760,
      actions: actions,
      richText: richText
    )
    message.globalId = stableId

    return FullMessage(
      senderInfo: nil,
      message: message,
      reactions: reactions,
      repliedToMessage: nil,
      attachments: []
    )
  }

  private func actionRowsFixture() -> MessageActions {
    var copyAction = MessageAction()
    copyAction.actionID = "copy-summary"
    copyAction.text = "Copy summary"
    var copyPayload = MessageActionCopyText()
    copyPayload.text = "Rich message action copy"
    copyAction.action = .copyText(copyPayload)

    var callbackAction = MessageAction()
    callbackAction.actionID = "rerun-rich"
    callbackAction.text = "Rerun"
    var callbackPayload = MessageActionCallback()
    callbackPayload.data = Data("rich.action.rerun".utf8)
    callbackAction.action = .callback(callbackPayload)

    var row = MessageActionRow()
    row.actions = [copyAction, callbackAction]

    var actions = MessageActions()
    actions.rows = [row]
    return actions
  }

  private func chromeRect(for plan: MessageSizeCalculator.LayoutPlan, top: CGFloat) -> CGRect {
    CGRect(
      x: plan.spacing.left,
      y: top,
      width: plan.size.width,
      height: plan.size.height
    )
  }

  private func chromeTimeRect(
    for layout: MessageSizeCalculator.LayoutPlans,
    time: MessageSizeCalculator.LayoutPlan
  ) -> CGRect {
    let x = max(0, layout.bubble.size.width - time.spacing.right - time.size.width)
    let y = layout.placesTimeAboveReactions
      ? layout.timeViewTop
      : max(0, layout.bubble.size.height - time.spacing.bottom - time.size.height)
    return CGRect(x: x, y: y, width: time.size.width, height: time.size.height)
  }

  private mutating func validateChromeRect(_ rect: CGRect, in bounds: CGRect, label: String) {
    checkChromeGeometry(isPositiveFinite(rect), "\(label) should have a finite measured rect")
    checkChromeGeometry(
      rect.minX >= -0.5 && rect.minY >= -0.5 &&
        rect.maxX <= bounds.width + 0.5 &&
        rect.maxY <= bounds.height + 0.5,
      "\(label) should fit inside measured bubble bounds"
    )
  }

  private func isPositiveFinite(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }

  private func isPositiveFinite(_ rect: CGRect) -> Bool {
    rect.minX.isFinite && rect.minY.isFinite &&
      rect.width.isFinite && rect.height.isFinite &&
      rect.width > 0 && rect.height > 0
  }

  private mutating func validateRowViewSlotTransitions(
    richMessage: FullMessage,
    plainMessage: FullMessage,
    peer: InlineKit.Peer
  ) {
    let richBubbleProps = viewProps(for: richMessage, renderStyle: .bubble)
    let plainBubbleProps = viewProps(for: plainMessage, renderStyle: .bubble)
    let richMinimalProps = viewProps(for: richMessage, renderStyle: .minimal)
    let plainMinimalProps = viewProps(for: plainMessage, renderStyle: .minimal)

    let richBubbleView = MessageViewAppKit(fullMessage: richMessage, props: richBubbleProps)
    validateSlot(
      richBubbleView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: true,
      label: "bubble initial rich row"
    )
    richBubbleView.updateTextAndSize(fullMessage: plainMessage, props: plainBubbleProps)
    validateSlot(
      richBubbleView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: false,
      label: "bubble rich-to-plain reused row"
    )

    let plainBubbleView = MessageViewAppKit(fullMessage: plainMessage, props: plainBubbleProps)
    validateSlot(
      plainBubbleView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: false,
      label: "bubble initial plain row"
    )
    plainBubbleView.updateTextAndSize(fullMessage: richMessage, props: richBubbleProps)
    validateSlot(
      plainBubbleView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: true,
      label: "bubble plain-to-rich reused row"
    )

    let richMinimalView = MinimalMessageViewAppKit(fullMessage: richMessage, props: richMinimalProps)
    validateSlot(
      richMinimalView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: true,
      label: "minimal initial rich row"
    )
    richMinimalView.updateTextAndSize(fullMessage: plainMessage, props: plainMinimalProps)
    validateSlot(
      richMinimalView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: false,
      label: "minimal rich-to-plain reused row"
    )

    let plainMinimalView = MinimalMessageViewAppKit(fullMessage: plainMessage, props: plainMinimalProps)
    validateSlot(
      plainMinimalView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: false,
      label: "minimal initial plain row"
    )
    plainMinimalView.updateTextAndSize(fullMessage: richMessage, props: richMinimalProps)
    validateSlot(
      plainMinimalView.debugRichTextSlotSnapshotForTestBook(),
      expectedRich: true,
      label: "minimal plain-to-rich reused row"
    )

    validateTableCellSlotTransitions(
      richMessage: richMessage,
      plainMessage: plainMessage,
      richProps: richBubbleProps,
      plainProps: plainBubbleProps,
      label: "bubble table cell"
    )
    validateTableCellSlotTransitions(
      richMessage: richMessage,
      plainMessage: plainMessage,
      richProps: richMinimalProps,
      plainProps: plainMinimalProps,
      label: "minimal table cell"
    )
    validateTableCellResize(
      richMessage: richMessage,
      renderStyle: .bubble,
      label: "bubble table cell"
    )
    validateTableCellResize(
      richMessage: richMessage,
      renderStyle: .minimal,
      label: "minimal table cell"
    )
    validateExperimentalFlagTableCellTransitions(richMessage: richMessage, renderStyle: .bubble)
    validateExperimentalFlagTableCellTransitions(richMessage: richMessage, renderStyle: .minimal)
    validateTableCellPrepareForReuse(
      richMessage: richMessage,
      plainMessage: plainMessage,
      richProps: richBubbleProps,
      plainProps: plainBubbleProps,
      label: "bubble table cell"
    )
    validateTableCellPrepareForReuse(
      richMessage: richMessage,
      plainMessage: plainMessage,
      richProps: richMinimalProps,
      plainProps: plainMinimalProps,
      label: "minimal table cell"
    )
    validateSyntheticTableViewRows(
      richMessage: richMessage,
      plainMessage: plainMessage,
      richBubbleProps: richBubbleProps,
      plainBubbleProps: plainBubbleProps,
      richMinimalProps: richMinimalProps,
      plainMinimalProps: plainMinimalProps
    )

    if let selectionRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "selection" })?.message {
      let selectionMessage = makeFullMessage(
        messageId: richMessage.message.messageId + 10,
        stableId: richMessage.id + 10,
        peer: peer,
        richText: selectionRichText
      )
      validateTableCellSelectionInteraction(
        richMessage: selectionMessage,
        props: viewProps(for: selectionMessage, renderStyle: .bubble),
        label: "bubble table cell selection interaction"
      )
      validateTableCellSelectionInteraction(
        richMessage: selectionMessage,
        props: viewProps(for: selectionMessage, renderStyle: .minimal),
        label: "minimal table cell selection interaction"
      )
    } else {
      check(false, "selection interaction fixture should exist")
    }
  }

  private mutating func validateTableCellSlotTransitions(
    richMessage: FullMessage,
    plainMessage: FullMessage,
    richProps: MessageViewProps,
    plainProps: MessageViewProps,
    label: String
  ) {
    let richCell = makeTableCell(size: tableCellSize(for: richProps))
    richCell.configure(with: richMessage, props: richProps, animate: false)
    validateCellSlot(richCell, expectedRich: true, label: "\(label) initial rich")
    richCell.configure(with: plainMessage, props: plainProps, animate: false)
    validateCellSlot(richCell, expectedRich: false, label: "\(label) rich-to-plain reuse")

    let plainCell = makeTableCell(size: tableCellSize(for: plainProps))
    plainCell.configure(with: plainMessage, props: plainProps, animate: false)
    validateCellSlot(plainCell, expectedRich: false, label: "\(label) initial plain")
    plainCell.configure(with: richMessage, props: richProps, animate: false)
    validateCellSlot(plainCell, expectedRich: true, label: "\(label) plain-to-rich reuse")
  }

  private mutating func validateCellSlot(
    _ cell: MessageTableCell,
    expectedRich: Bool,
    label: String
  ) {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
      check(false, "\(label) should expose a row slot snapshot")
      return
    }
    validateSlot(snapshot, expectedRich: expectedRich, label: label)
  }

  private mutating func validateTableCellResize(
    richMessage: FullMessage,
    renderStyle: MessageRenderStyle,
    label: String
  ) {
    let wideTableWidth: CGFloat = 720
    let narrowTableWidth: CGFloat = 420
    let wideProps = viewProps(for: richMessage, renderStyle: renderStyle, tableWidth: wideTableWidth)
    let narrowProps = viewProps(for: richMessage, renderStyle: renderStyle, tableWidth: narrowTableWidth)

    check(wideProps.equalExceptSize(narrowProps), "\(label) resize props should differ only by size")
    check(
      wideProps.layout.hasSameConstraintShape(as: narrowProps.layout),
      "\(label) resize props should keep the same constraint shape"
    )

    let cell = makeTableCell(size: tableCellSize(for: wideProps, tableWidth: wideTableWidth))
    cell.configure(with: richMessage, props: wideProps, animate: false)
    guard let wideSnapshot = cellSlotSnapshot(cell, label: "\(label) wide resize seed") else { return }
    let viewID = cell.debugRenderableViewIDForTestBook()

    cell.frame = NSRect(origin: .zero, size: tableCellSize(for: narrowProps, tableWidth: narrowTableWidth))
    cell.configure(with: richMessage, props: narrowProps, animate: false)
    guard let narrowSnapshot = cellSlotSnapshot(cell, label: "\(label) narrow resize result") else { return }

    check(viewID != nil, "\(label) resize should expose initial render view identity")
    check(
      cell.debugRenderableViewIDForTestBook() == viewID,
      "\(label) size-only update should reuse the existing render view"
    )
    validateSlot(narrowSnapshot, expectedRich: true, label: "\(label) narrow resize result")

    guard let wideWidth = wideSnapshot.widthConstraintConstant,
          let narrowWidth = narrowSnapshot.widthConstraintConstant
    else {
      check(false, "\(label) resize should expose width constraint constants")
      return
    }
    check(
      narrowWidth < wideWidth - 0.5,
      "\(label) resize should shrink rich text slot width from \(wideWidth) to \(narrowWidth)"
    )
    check(
      (narrowSnapshot.heightConstraintConstant ?? 0) > 0,
      "\(label) resize should keep a positive rich text slot height"
    )
  }

  private mutating func validateExperimentalFlagTableCellTransitions(
    richMessage: FullMessage,
    renderStyle: MessageRenderStyle
  ) {
    let label = "\(renderStyle.title.lowercased()) table cell feature flag"
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    defer {
      restoreRichFlag(oldRichFlag)
      CacheAttrs.shared.invalidate()
      calculator.debugClearRichBlockStateAndLayouts(for: richMessage.id)
    }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(false)
    CacheAttrs.shared.invalidate()
    calculator.debugClearRichBlockStateAndLayouts(for: richMessage.id)
    let fallbackProps = viewProps(for: richMessage, renderStyle: renderStyle)
    let cell = makeTableCell(size: tableCellSize(for: fallbackProps))
    cell.configure(with: richMessage, props: fallbackProps, animate: false)
    validateCellSlot(cell, expectedRich: false, label: "\(label) disabled")
    check(
      calculator.debugRichBlockLayoutCacheCount(for: richMessage.id) == 0,
      "\(label) disabled should not populate rich layout cache"
    )

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    CacheAttrs.shared.invalidate()
    calculator.debugClearRichBlockStateAndLayouts(for: richMessage.id)
    let richProps = viewProps(for: richMessage, renderStyle: renderStyle)
    cell.frame = NSRect(origin: .zero, size: tableCellSize(for: richProps))
    cell.configure(with: richMessage, props: richProps, animate: false)
    validateCellSlot(cell, expectedRich: true, label: "\(label) enabled")
    check(
      calculator.debugRichBlockLayoutCacheCount(for: richMessage.id) > 0,
      "\(label) enabled should populate rich layout cache"
    )
  }

  private mutating func validateTableCellPrepareForReuse(
    richMessage: FullMessage,
    plainMessage: FullMessage,
    richProps: MessageViewProps,
    plainProps: MessageViewProps,
    label: String
  ) {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    defer { restoreRichFlag(oldRichFlag) }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    let cell = makeTableCell(size: tableCellSize(for: richProps))
    cell.configure(with: richMessage, props: richProps, animate: false)
    validateCellSlot(cell, expectedRich: true, label: "\(label) prepareForReuse initial rich")
    let viewID = cell.debugRenderableViewIDForTestBook()
    guard let interaction = cell.debugRichTextInteractionSnapshotForTestBook() else {
      check(false, "\(label) prepareForReuse initial rich should expose interaction snapshot")
      return
    }
    check(
      !interaction.dragSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "\(label) prepareForReuse should create a selected rich range before reset"
    )

    cell.prepareForReuse()
    check(
      cell.debugSelectedRichTextForTestBook().isEmpty,
      "\(label) prepareForReuse should clear selected rich text before reuse"
    )
    cell.frame = NSRect(origin: .zero, size: tableCellSize(for: plainProps))
    cell.configure(with: plainMessage, props: plainProps, animate: false)
    validateCellSlot(cell, expectedRich: false, label: "\(label) prepareForReuse rich-to-plain")
    check(
      cell.debugRenderableViewIDForTestBook() == viewID,
      "\(label) prepareForReuse rich-to-plain should reuse the render view"
    )

    cell.prepareForReuse()
    cell.frame = NSRect(origin: .zero, size: tableCellSize(for: richProps))
    cell.configure(with: richMessage, props: richProps, animate: false)
    validateCellSlot(cell, expectedRich: true, label: "\(label) prepareForReuse plain-to-rich")
    check(
      cell.debugRenderableViewIDForTestBook() == viewID,
      "\(label) prepareForReuse plain-to-rich should reuse the render view"
    )
  }

  private mutating func validateSyntheticTableViewRows(
    richMessage: FullMessage,
    plainMessage: FullMessage,
    richBubbleProps: MessageViewProps,
    plainBubbleProps: MessageViewProps,
    richMinimalProps: MessageViewProps,
    plainMinimalProps: MessageViewProps
  ) {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    defer { restoreRichFlag(oldRichFlag) }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    let rows = [
      RichLiveRowTableHarness.Row(
        message: richMessage,
        props: richBubbleProps,
        expectedRich: true,
        label: "synthetic table bubble rich"
      ),
      RichLiveRowTableHarness.Row(
        message: plainMessage,
        props: plainBubbleProps,
        expectedRich: false,
        label: "synthetic table bubble plain"
      ),
      RichLiveRowTableHarness.Row(
        message: richMessage,
        props: richMinimalProps,
        expectedRich: true,
        label: "synthetic table minimal rich"
      ),
      RichLiveRowTableHarness.Row(
        message: plainMessage,
        props: plainMinimalProps,
        expectedRich: false,
        label: "synthetic table minimal plain"
      ),
    ]
    let swappedRows = [
      RichLiveRowTableHarness.Row(
        message: plainMessage,
        props: plainBubbleProps,
        expectedRich: false,
        label: "synthetic table reload bubble plain"
      ),
      RichLiveRowTableHarness.Row(
        message: richMessage,
        props: richBubbleProps,
        expectedRich: true,
        label: "synthetic table reload bubble rich"
      ),
      RichLiveRowTableHarness.Row(
        message: plainMessage,
        props: plainMinimalProps,
        expectedRich: false,
        label: "synthetic table reload minimal plain"
      ),
      RichLiveRowTableHarness.Row(
        message: richMessage,
        props: richMinimalProps,
        expectedRich: true,
        label: "synthetic table reload minimal rich"
      ),
    ]
    let harness = RichLiveRowTableHarness(tableWidth: 720)

    validateSyntheticTableViewRows(rows, in: harness, label: "synthetic table initial")
    validateSyntheticTableViewRows(swappedRows, in: harness, label: "synthetic table reload")
    check(
      harness.renderedViewCount >= rows.count + swappedRows.count,
      "synthetic table should ask for row views across initial and reload passes"
    )
    validateSyntheticTableViewScrolling(peer: .thread(id: 98_760), richMessage: richMessage)
  }

  private mutating func validateSyntheticTableViewRows(
    _ rows: [RichLiveRowTableHarness.Row],
    in harness: RichLiveRowTableHarness,
    label: String
  ) {
    harness.load(rows)
    check(harness.numberOfRows(in: harness.tableView) == rows.count, "\(label) should expose all rows")

    for (index, row) in rows.enumerated() {
      let height = harness.tableView(harness.tableView, heightOfRow: index)
      check(
        abs(height - row.height) < 0.5,
        "\(row.label) height should match the precomputed message layout"
      )
      let rect = harness.tableView.rect(ofRow: index)
      check(rect.height > 0, "\(row.label) table rect should have positive height")
      guard let cell = harness.cell(at: index) else {
        check(false, "\(row.label) should produce a MessageTableCell")
        continue
      }
      validateCellSlot(cell, expectedRich: row.expectedRich, label: row.label)
      if row.expectedRich {
        validateCellRootInteraction(cell, label: row.label)
      }
      check(
        cell.debugRenderableViewIDForTestBook() != nil,
        "\(row.label) should expose a render view identity"
      )
    }
  }

  private mutating func validateSyntheticTableViewScrolling(peer: InlineKit.Peer, richMessage: FullMessage) {
    let richText = richMessage.message.richText ?? RichMessageTestFixtures.samples[0].message
    let baseMessageId: Int64 = 98_770_000
    let rows: [RichLiveRowTableHarness.Row] = (0..<28).map { index in
      let renderStyle: MessageRenderStyle = index.isMultiple(of: 2) ? .bubble : .minimal
      let usesRich = index % 3 != 1
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: usesRich ? richText : nil
      )
      return RichLiveRowTableHarness.Row(
        message: message,
        props: viewProps(for: message, renderStyle: renderStyle),
        expectedRich: usesRich,
        label: "synthetic scroll row \(index) \(renderStyle.title.lowercased()) \(usesRich ? "rich" : "plain")"
      )
    }
    defer {
      for row in rows {
        calculator.debugClearRichBlockStateAndLayouts(for: row.message.id)
      }
    }

    let harness = RichLiveRowTableHarness(tableWidth: 720, viewportHeight: 180)
    harness.load(rows)
    checkTableScroll(harness.numberOfRows(in: harness.tableView) == rows.count, "synthetic scroll table should expose all rows")

    for targetRow in [0, 7, 15, 27, 3, 22] {
      validateSyntheticScrollTarget(targetRow, rows: rows, in: harness)
    }

    checkTableScroll(
      harness.renderedViewCount > 0,
      "synthetic scroll table should request visible row views"
    )
  }

  private mutating func validateSyntheticScrollTarget(
    _ targetRow: Int,
    rows: [RichLiveRowTableHarness.Row],
    in harness: RichLiveRowTableHarness
  ) {
    harness.scrollRowToVisible(targetRow)
    let visibleRows = harness.visibleRowIndexes()
    checkTableScroll(!visibleRows.isEmpty, "synthetic scroll target \(targetRow) should produce visible rows")
    checkTableScroll(
      visibleRows.contains(targetRow),
      "synthetic scroll target \(targetRow) should be in visible rows \(visibleRows)"
    )

    for rowIndex in visibleRows.prefix(6) {
      guard rows.indices.contains(rowIndex) else {
        checkTableScroll(false, "synthetic scroll visible row \(rowIndex) should be in row bounds")
        continue
      }
      let row = rows[rowIndex]
      let rect = harness.tableView.rect(ofRow: rowIndex)
      checkTableScroll(rect.height > 0, "\(row.label) visible rect should have positive height")
      guard let cell = harness.cell(at: rowIndex) else {
        checkTableScroll(false, "\(row.label) should produce a visible MessageTableCell after scrolling")
        continue
      }
      validateCellSlotForTableScroll(cell, expectedRich: row.expectedRich, label: row.label)
    }
  }

  private mutating func validateCellSlotForTableScroll(
    _ cell: MessageTableCell,
    expectedRich: Bool,
    label: String
  ) {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
      checkTableScroll(false, "\(label) should expose a row slot snapshot after scrolling")
      return
    }
    checkTableScroll(
      snapshot.usesRichBlockRenderer == expectedRich,
      "\(label) should \(expectedRich ? "use" : "not use") the rich block renderer after scrolling"
    )
    checkTableScroll(
      snapshot.richViewAttached == expectedRich,
      "\(label) rich block view attachment should match renderer mode after scrolling"
    )
    checkTableScroll(
      snapshot.textViewAttached != expectedRich,
      "\(label) fallback text view attachment should be opposite renderer mode after scrolling"
    )
    checkTableScroll(
      snapshot.hasActiveTextSlotConstraints,
      "\(label) should keep active text slot constraints after scrolling"
    )
  }

  private mutating func validateRichMediaScrollStatePropagation(
    richText: RichMessage,
    peer: InlineKit.Peer
  ) {
    let baseMessageId: Int64 = 98_780_000
    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: richText
      )
      defer {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let label = "rich media scroll \(renderStyle.title.lowercased())"
      let props = viewProps(for: message, renderStyle: renderStyle)
      let expectedMediaFrameSizes = expectedMountedMediaFrameSizes(
        richText: richText,
        width: props.layout.text?.size.width ?? 520,
        fontSize: props.layout.fontSize
      )
      let cell = makeTableCell(size: tableCellSize(for: props))
      cell.setScrollState(.idle)
      cell.configure(with: message, props: props, animate: false)
      validateRichMediaScrollSnapshot(
        cell,
        expectedScrolling: false,
        expectedMediaFrameSizes: expectedMediaFrameSizes,
        label: "\(label) initial idle"
      )

      cell.setScrollState(.scrolling)
      validateRichMediaScrollSnapshot(
        cell,
        expectedScrolling: true,
        expectedMediaFrameSizes: expectedMediaFrameSizes,
        label: "\(label) scrolling"
      )

      cell.setScrollState(.idle)
      validateRichMediaScrollSnapshot(
        cell,
        expectedScrolling: false,
        expectedMediaFrameSizes: expectedMediaFrameSizes,
        label: "\(label) restored idle"
      )
    }
  }

  private mutating func validateRichMediaScrollSnapshot(
    _ cell: MessageTableCell,
    expectedScrolling: Bool,
    expectedMediaFrameSizes: [CGSize],
    label: String
  ) {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichMediaScrollSnapshotForTestBook() else {
      checkMediaScroll(false, "\(label) should expose row-mounted rich media scroll snapshot")
      return
    }

    checkMediaScroll(snapshot.mediaViewCount > 0, "\(label) should include at least one rich media view")
    checkMediaScroll(
      snapshot.mediaViewFrames.count == snapshot.mediaViewCount,
      "\(label) should expose a frame for every rich media view"
    )
    checkMediaScroll(
      roundedSizeKeys(snapshot.mediaViewFrames.map(\.size)) == roundedSizeKeys(expectedMediaFrameSizes),
      "\(label) media frames should match precomputed rich media layout sizes actual=\(roundedSizeKeys(snapshot.mediaViewFrames.map(\.size)).joined(separator: ",")) expected=\(roundedSizeKeys(expectedMediaFrameSizes).joined(separator: ","))"
    )
    if expectedScrolling {
      checkMediaScroll(
        snapshot.scrollingMediaViewCount == snapshot.mediaViewCount,
        "\(label) should mark all \(snapshot.mediaViewCount) rich media views as scrolling"
      )
      checkMediaScroll(snapshot.idleMediaViewCount == 0, "\(label) should not leave idle rich media views")
      checkMediaScroll(
        snapshot.scrollingNativeMediaViewCount == snapshot.nativeMediaViewCount,
        "\(label) should mark all \(snapshot.nativeMediaViewCount) native rich media views as scrolling"
      )
      return
    }

    checkMediaScroll(
      snapshot.idleMediaViewCount == snapshot.mediaViewCount,
      "\(label) should mark all \(snapshot.mediaViewCount) rich media views as idle"
    )
    checkMediaScroll(snapshot.scrollingMediaViewCount == 0, "\(label) should not leave scrolling rich media views")
    checkMediaScroll(
      snapshot.idleNativeMediaViewCount == snapshot.nativeMediaViewCount,
      "\(label) should mark all \(snapshot.nativeMediaViewCount) native rich media views as idle"
    )
  }

  private func expectedMountedMediaFrameSizes(
    richText: RichMessage,
    width: CGFloat,
    fontSize: CGFloat
  ) -> [CGSize] {
    let rowStyle = RichMessageBlockStyle.message(
      fontSize: fontSize,
      primary: .labelColor,
      secondary: .secondaryLabelColor,
      link: .linkColor
    )
    let layout = RichMessageBlockSizeCalculator.layout(
      for: richText,
      width: width,
      style: rowStyle,
      state: .initial
    )
    var sizes: [CGSize] = []
    appendMountedMediaFrameSizes(from: layout.root, into: &sizes)
    return sizes
  }

  private func appendMountedMediaFrameSizes(from layout: RichBlocksLayoutPlan, into sizes: inout [CGSize]) {
    for item in layout.items {
      switch item.node.block.block {
      case .photo, .video, .document:
        if let mediaLayout = item.mediaLayout {
          sizes.append(mediaLayout.mediaFrame.size)
        }
      case .linkPreview:
        if let mediaFrame = item.linkPreviewLayout?.mediaFrame {
          sizes.append(mediaFrame.size)
        }
      case .embed:
        if let mediaFrame = item.embedLayout?.mediaFrame {
          sizes.append(mediaFrame.size)
        }
      case .embedPost:
        if let authorPhotoFrame = item.embedPostLayout?.authorPhotoFrame {
          sizes.append(authorPhotoFrame.size)
        }
      default:
        break
      }

      for child in item.children.values {
        appendMountedMediaFrameSizes(from: child, into: &sizes)
      }
    }
  }

  private func roundedSizeKeys(_ sizes: [CGSize]) -> [String] {
    sizes
      .map { "\(Int(round($0.width)))x\(Int(round($0.height)))" }
      .sorted()
  }

  private mutating func validateRichStateUpdateRowRefresh(
    richText: RichMessage,
    peer: InlineKit.Peer
  ) {
    let baseMessageId: Int64 = 98_790_000
    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: richText
      )
      defer {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let label = "rich state update \(renderStyle.title.lowercased())"
      calculator.setRichBlockState(.initial, for: message.id)
      let collapsedProps = viewProps(for: message, renderStyle: renderStyle)
      let cell = makeTableCell(size: tableCellSize(for: collapsedProps))
      cell.configure(with: message, props: collapsedProps, animate: false)
      guard let collapsedSnapshot = cellSlotSnapshotForStateUpdate(cell, label: "\(label) collapsed") else {
        continue
      }
      let renderViewID = cell.debugRenderableViewIDForTestBook()
      let collapsedHeight = collapsedSnapshot.heightConstraintConstant ?? 0
      checkStateUpdate(collapsedSnapshot.usesRichBlockRenderer, "\(label) collapsed should use rich renderer")
      checkStateUpdate(renderViewID != nil, "\(label) should expose initial render view identity")
      validateStateUpdateInteraction(cell, label: "\(label) collapsed")

      calculator.setRichBlockState(
        RichMessageBlockStateSnapshot(overrides: ["thinking": true, "details": true]),
        for: message.id
      )
      let expandedProps = viewProps(for: message, renderStyle: renderStyle)
      checkStateUpdate(
        expandedProps.layout.totalHeight > collapsedProps.layout.totalHeight + 0.5,
        "\(label) expanded props should grow row height"
      )
      cell.frame = NSRect(origin: .zero, size: tableCellSize(for: expandedProps))
      cell.updateTextAndSizeWithProps(props: expandedProps)
      guard let expandedSnapshot = cellSlotSnapshotForStateUpdate(cell, label: "\(label) expanded") else {
        continue
      }
      checkStateUpdate(
        cell.debugRenderableViewIDForTestBook() == renderViewID,
        "\(label) expanded update should reuse the row render view"
      )
      checkStateUpdate(expandedSnapshot.usesRichBlockRenderer, "\(label) expanded should still use rich renderer")
      checkStateUpdate(
        (expandedSnapshot.heightConstraintConstant ?? 0) > collapsedHeight + 0.5,
        "\(label) expanded rich slot should grow from \(collapsedHeight)"
      )
      checkStateUpdate(
        expandedSnapshot.hasActiveTextSlotConstraints,
        "\(label) expanded should keep active text slot constraints"
      )
      validateStateUpdateInteraction(cell, label: "\(label) expanded")

      calculator.setRichBlockState(.initial, for: message.id)
      let restoredProps = viewProps(for: message, renderStyle: renderStyle)
      cell.frame = NSRect(origin: .zero, size: tableCellSize(for: restoredProps))
      cell.updateTextAndSizeWithProps(props: restoredProps)
      guard let restoredSnapshot = cellSlotSnapshotForStateUpdate(cell, label: "\(label) restored") else {
        continue
      }
      checkStateUpdate(
        cell.debugRenderableViewIDForTestBook() == renderViewID,
        "\(label) restored update should reuse the row render view"
      )
      checkStateUpdate(restoredSnapshot.usesRichBlockRenderer, "\(label) restored should still use rich renderer")
      checkStateUpdate(
        abs((restoredSnapshot.heightConstraintConstant ?? 0) - collapsedHeight) < 0.5,
        "\(label) restored rich slot should return to collapsed height"
      )
      validateStateUpdateInteraction(cell, label: "\(label) restored")
    }
  }

  private mutating func validateRichDraftStreamingRowRefresh(
    durableRichText: RichMessage,
    peer: InlineKit.Peer
  ) {
    let draftStages = RichMessageTestFixtures.streamingDraftStages
    guard !draftStages.isEmpty else {
      checkDraftStreaming(false, "draft streaming gate should have staged rich draft fixtures")
      return
    }

    let baseMessageId: Int64 = 98_795_000
    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: durableRichText
      )
      let draftId = "rich-testbook-streaming-row-\(message.id)"
      defer {
        clearDraft(draftId: draftId, peer: peer, messageId: message.message.messageId)
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let label = "rich draft streaming \(renderStyle.title.lowercased())"
      var cell: MessageTableCell?
      var renderViewID: ObjectIdentifier?

      for (stageIndex, draftRichText) in draftStages.enumerated() {
        applyDraft(draftId: draftId, peer: peer, messageId: message.message.messageId, richText: draftRichText)
        calculator.invalidateRichBlockLayouts(for: message.id)
        checkDraftStreaming(
          calculator.effectiveRichText(for: message)?.stableSignature == draftRichText.stableSignature,
          "\(label) stage \(stageIndex) should use the active rich draft payload"
        )

        let props = viewProps(for: message, renderStyle: renderStyle)
        checkDraftStreaming(props.layout.text != nil, "\(label) stage \(stageIndex) should precompute a rich text slot")
        let nextSize = tableCellSize(for: props)

        if cell == nil {
          let nextCell = makeTableCell(size: nextSize)
          nextCell.configure(with: message, props: props, animate: false)
          validateCellSlot(nextCell, expectedRich: true, label: "\(label) stage \(stageIndex)")
          cell = nextCell
          renderViewID = nextCell.debugRenderableViewIDForTestBook()
          checkDraftStreaming(renderViewID != nil, "\(label) should expose initial row render view identity")
        } else if let currentCell = cell {
          currentCell.frame = NSRect(origin: .zero, size: nextSize)
          currentCell.updateTextAndSizeWithProps(props: props)
          checkDraftStreaming(
            currentCell.debugRenderableViewIDForTestBook() == renderViewID,
            "\(label) stage \(stageIndex) should reuse the mounted row render view"
          )
        }

        guard let currentCell = cell,
              let snapshot = cellSlotSnapshotForDraftStreaming(currentCell, label: "\(label) stage \(stageIndex)")
        else {
          continue
        }

        let slotHeight = snapshot.heightConstraintConstant ?? 0
        checkDraftStreaming(snapshot.usesRichBlockRenderer, "\(label) stage \(stageIndex) should use rich renderer")
        checkDraftStreaming(slotHeight > 0, "\(label) stage \(stageIndex) should keep positive rich slot height")
        if let textPlan = props.layout.text {
          checkDraftStreaming(
            abs(slotHeight - textPlan.size.height) < 0.5,
            "\(label) stage \(stageIndex) rich slot height should match precomputed draft layout"
          )
        }
        validateDraftStreamingInteraction(currentCell, label: "\(label) stage \(stageIndex)")
      }

      if let cell {
        validateDraftStreamingReuseDiagnostics(cell, label: label)
      }

      clearDraft(draftId: draftId, peer: peer, messageId: message.message.messageId)
      calculator.invalidateRichBlockLayouts(for: message.id)
      checkDraftStreaming(
        calculator.effectiveRichText(for: message)?.stableSignature == durableRichText.stableSignature,
        "\(label) clear should restore durable rich payload"
      )

      guard let cell else {
        checkDraftStreaming(false, "\(label) should keep a mounted row through draft stages")
        continue
      }

      let restoredProps = viewProps(for: message, renderStyle: renderStyle)
      cell.frame = NSRect(origin: .zero, size: tableCellSize(for: restoredProps))
      cell.updateTextAndSizeWithProps(props: restoredProps)
      checkDraftStreaming(
        cell.debugRenderableViewIDForTestBook() == renderViewID,
        "\(label) durable restore should reuse the mounted row render view"
      )
      guard let restoredSnapshot = cellSlotSnapshotForDraftStreaming(cell, label: "\(label) durable restore") else {
        continue
      }
      checkDraftStreaming(restoredSnapshot.usesRichBlockRenderer, "\(label) durable restore should use rich renderer")
      checkDraftStreaming(
        abs((restoredSnapshot.heightConstraintConstant ?? 0) - (restoredProps.layout.text?.size.height ?? 0)) < 0.5,
        "\(label) durable restore height should match precomputed durable layout"
      )
      validateDraftStreamingInteraction(cell, label: "\(label) durable restore")
    }
  }

  private mutating func validateRichActionRows(
    richText: RichMessage,
    peer: InlineKit.Peer
  ) {
    let actions = actionRowsFixture()
    let expectedRowCount = actions.rows.count
    let expectedActionCount = actions.rows.reduce(0) { $0 + $1.actions.count }
    let baseMessageId: Int64 = 98_800_000

    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: richText,
        actions: actions
      )
      defer {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let label = "rich action rows \(renderStyle.title.lowercased())"
      let props = viewProps(for: message, renderStyle: renderStyle)
      guard let actionsPlan = props.layout.actionsRows else {
        checkActionRows(false, "\(label) should have a precomputed action rows layout")
        continue
      }

      let cell = makeTableCell(size: tableCellSize(for: props))
      cell.configure(with: message, props: props, animate: false)
      validateCellSlot(cell, expectedRich: true, label: label)
      guard let snapshot = cell.debugMessageActionRowsSnapshotForTestBook() else {
        checkActionRows(false, "\(label) should expose message action row snapshot")
        continue
      }

      checkActionRows(snapshot.attached, "\(label) action rows should be attached to the row")
      checkActionRows(snapshot.hasActiveConstraints, "\(label) action rows should keep active constraints")
      checkActionRows(snapshot.rowCount == expectedRowCount, "\(label) should expose \(expectedRowCount) action row(s)")
      checkActionRows(
        snapshot.actionCount == expectedActionCount,
        "\(label) should expose \(expectedActionCount) action button(s)"
      )
      checkActionRows(
        snapshot.hitTestableActionCount == expectedActionCount,
        "\(label) should keep every action button hit-testable"
      )
      checkActionRows(
        snapshot.hoverResponsiveActionCount == expectedActionCount,
        "\(label) should keep every action button hover-responsive"
      )
      checkActionRows(
        snapshot.pressResponsiveActionCount == expectedActionCount,
        "\(label) should keep every action button press-responsive"
      )
      checkActionRows(
        snapshot.restoredInteractionActionCount == expectedActionCount,
        "\(label) should restore every action button after hover/press diagnostics"
      )
      checkActionRows(
        abs((snapshot.widthConstraintConstant ?? 0) - actionsPlan.size.width) < 0.5,
        "\(label) action rows width should match precomputed layout"
      )
      checkActionRows(
        abs((snapshot.heightConstraintConstant ?? 0) - actionsPlan.size.height) < 0.5,
        "\(label) action rows height should match precomputed layout"
      )
      checkActionRows(
        abs(snapshot.frameWidth - actionsPlan.size.width) < 0.5,
        "\(label) action rows frame width should match constraints"
      )
      checkActionRows(
        abs(snapshot.frameHeight - actionsPlan.size.height) < 0.5,
        "\(label) action rows frame height should match constraints"
      )
    }
  }

  private mutating func validateRichTimeStatusMountedRows(
    richText: RichMessage,
    peer: InlineKit.Peer
  ) {
    let baseMessageId: Int64 = 98_810_000
    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index * 10),
        stableId: baseMessageId + Int64(index * 10),
        peer: peer,
        richText: richText
      )
      defer {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let label = "rich time/status \(renderStyle.title.lowercased())"
      let props = viewProps(for: message, renderStyle: renderStyle)
      guard let time = props.layout.time else {
        checkTimeStatus(false, "\(label) should have a precomputed time/status layout")
        continue
      }

      let cell = makeTableCell(size: tableCellSize(for: props))
      cell.configure(with: message, props: props, animate: false)
      validateCellSlot(cell, expectedRich: true, label: label)
      guard let snapshot = cell.debugTimeStatusSnapshotForTestBook() else {
        checkTimeStatus(false, "\(label) should expose mounted time/status snapshot")
        continue
      }

      checkTimeStatus(snapshot.attached, "\(label) time/status view should be attached")
      checkTimeStatus(
        abs(snapshot.frameInBubble.width - time.size.width) < 0.5,
        "\(label) mounted time/status width should match precomputed layout"
      )
      checkTimeStatus(
        abs(snapshot.frameInBubble.height - time.size.height) < 0.5,
        "\(label) mounted time/status height should match precomputed layout"
      )
      checkTimeStatus(snapshot.widthConstraintActive, "\(label) time/status should keep active width constraint")
      checkTimeStatus(snapshot.heightConstraintActive, "\(label) time/status should keep active height constraint")
      checkTimeStatus(
        abs((snapshot.widthConstraintConstant ?? 0) - time.size.width) < 0.5,
        "\(label) time/status width constraint should match deterministic layout"
      )
      checkTimeStatus(
        abs((snapshot.heightConstraintConstant ?? 0) - time.size.height) < 0.5,
        "\(label) time/status height constraint should match deterministic layout"
      )

      switch renderStyle {
      case .bubble:
        validateBubbleTimeStatusSnapshot(snapshot, layout: props.layout, time: time, label: label)
      case .minimal:
        validateMinimalTimeStatusSnapshot(snapshot, layout: props.layout, time: time, label: label)
      }
    }
  }

  @MainActor private mutating func validateMessageListControllerMount(
    durableRichText: RichMessage,
    peer _: InlineKit.Peer
  ) {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    let controllerPeer = InlineKit.Peer.user(id: 98_761)
    let chat = Chat(
      id: 98_760,
      date: Date(timeIntervalSince1970: 1_782_144_000),
      type: .privateChat,
      title: "Rich Text Controller Gate",
      spaceId: nil,
      peerUserId: 98_761
    )
    let mediaRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "media" })?.message ?? durableRichText
    let rtlRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "rtl" })?.message ?? durableRichText
    let richTexts: [RichMessage?] = [
      durableRichText,
      nil,
      mediaRichText,
      durableRichText,
      nil,
      rtlRichText,
      durableRichText,
      nil,
      mediaRichText,
      rtlRichText,
      nil,
      durableRichText,
    ]
    let baseMessageId: Int64 = 98_820_000
    let messages = richTexts.enumerated().map { index, richText in
      makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: controllerPeer,
        richText: richText
      )
    }
    let richMessageCount = richTexts.compactMap { $0 }.count
    let plainMessageCount = richTexts.count - richMessageCount
    let initialState = MessagesProgressiveViewModel.InitialState(
      messages: messages,
      oldestLoadedMessageId: messages.first?.message.messageId,
      newestLoadedMessageId: messages.last?.message.messageId,
      canLoadOlderFromLocal: false,
      canLoadNewerFromLocal: false
    )
    let controller = MessageListAppKit(
      richTextTestBookPeerId: controllerPeer,
      chat: chat,
      initialState: initialState
    )
    let size = CGSize(width: 760, height: 420)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller

    defer {
      controller.dispose()
      window.contentViewController = nil
      window.close()
      for message in messages {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }
      CacheAttrs.shared.invalidate()
      if let oldRichFlag {
        UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      } else {
        UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      }
    }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(false)
    controller.debugPrepareRichTextControllerForTestBook(size: size)
    let fallbackSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      fallbackSnapshot.messageRowCount == messages.count,
      "controller gate fallback should expose all synthetic message rows"
    )
    checkController(
      fallbackSnapshot.richRowCount == 0,
      "controller gate fallback should not mount rich renderers while the feature flag is off"
    )
    checkController(
      fallbackSnapshot.fallbackRowCount == messages.count,
      "controller gate fallback should mount fallback text for every message row"
    )
    checkController(
      fallbackSnapshot.constrainedRowCount == messages.count,
      "controller gate fallback rows should keep active text slot constraints"
    )
    checkController(
      fallbackSnapshot.finiteHeightCount == fallbackSnapshot.rowCount,
      "controller gate fallback should compute finite heights for every row"
    )

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    controller.debugRefreshRichTextControllerForTestBook()
    let richSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      richSnapshot.messageRowCount == messages.count,
      "controller gate rich mode should keep all synthetic message rows"
    )
    checkController(
      richSnapshot.richRowCount == richMessageCount,
      "controller gate rich mode should mount rich renderers for every rich message row"
    )
    checkController(
      richSnapshot.fallbackRowCount == plainMessageCount,
      "controller gate rich mode should keep fallback text only for plain message rows"
    )
    checkController(
      richSnapshot.constrainedRowCount == messages.count,
      "controller gate rich mode should keep active text slot constraints on every message row"
    )
    checkController(
      richSnapshot.finiteHeightCount == richSnapshot.rowCount,
      "controller gate rich mode should compute finite heights for every row"
    )
    checkController(
      richSnapshot.contentHeight > size.height,
      "controller gate rich list should create enough content to exercise scrolling"
    )
    checkController(
      richSnapshot.madeMessageCellCount >= messages.count,
      "controller gate rich mode should create message cells through MessageListAppKit"
    )
    checkController(
      richSnapshot.rowHeightQueryCount >= richSnapshot.rowCount,
      "controller gate rich mode should query row heights through MessageListAppKit"
    )

    controller.debugScrollRichTextControllerForTestBook(to: max(0, richSnapshot.rowCount - 1))
    let scrolledSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      scrolledSnapshot.scrollOffsetY >= 0,
      "controller gate scroll should keep a valid non-negative scroll offset"
    )
    checkController(
      scrolledSnapshot.scrollOffsetY > 0,
      "controller gate scroll should move within oversized rich content"
    )
    checkController(
      scrolledSnapshot.scrollOffsetY <= max(0, scrolledSnapshot.contentHeight - size.height) + 1,
      "controller gate scroll should stay inside document bounds"
    )
  }

  @MainActor private mutating func validateMessageListControllerDatabaseMount(
    durableRichText: RichMessage
  ) {
    let oldRichFlag = UserDefaults.standard.object(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    let controllerPeer = InlineKit.Peer.user(id: 98_831)
    let chatId: Int64 = 98_830
    let senderId: Int64 = 98_832
    let peerUserId: Int64 = 98_831
    let baseMessageId: Int64 = 98_830_000
    let date = Date(timeIntervalSince1970: 1_782_144_000)
    let mediaRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "media" })?.message ?? durableRichText
    let rtlRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "rtl" })?.message ?? durableRichText
    let tableRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "table" })?.message ?? durableRichText
    let richTexts: [RichMessage?] = [
      durableRichText,
      nil,
      mediaRichText,
      tableRichText,
      nil,
      rtlRichText,
      durableRichText,
      nil,
      mediaRichText,
      tableRichText,
      rtlRichText,
      nil,
      durableRichText,
      nil,
    ]
    let richMessageCount = richTexts.compactMap { $0 }.count
    let plainMessageCount = richTexts.count - richMessageCount
    let chat = Chat(
      id: chatId,
      date: date,
      type: .privateChat,
      title: "Rich Text DB Controller Gate",
      spaceId: nil,
      peerUserId: peerUserId
    )
    let appDb: AppDatabase
    var stableIds: [Int64] = []

    do {
      let queue = try DatabaseQueue(configuration: AppDatabase.makeConfiguration(passphrase: "123"))
      appDb = try AppDatabase(queue)
      stableIds = try appDb.dbWriter.write { db in
        try User(id: senderId, email: nil, firstName: "Rich Sender").insert(db)
        try User(id: peerUserId, email: nil, firstName: "Rich Peer").insert(db)
        try chat.insert(db)

        var savedStableIds: [Int64] = []
        for (index, richText) in richTexts.enumerated() {
          var message = Message(
            messageId: baseMessageId + Int64(index),
            fromId: senderId,
            date: date.addingTimeInterval(TimeInterval(index)),
            text: richText?.fallbackText ?? "Plain DB fallback row \(index + 1).",
            peerUserId: peerUserId,
            peerThreadId: nil,
            chatId: chatId,
            out: senderId == peerUserId,
            richText: richText
          )
          let saved = try message.saveMessage(db)
          savedStableIds.append(saved.globalId ?? saved.messageId)
        }

        if let lastMessageId = richTexts.indices.last.map({ baseMessageId + Int64($0) }) {
          var updatedChat = chat
          updatedChat.lastMsgId = lastMessageId
          try updatedChat.update(db)
        }

        return savedStableIds
      }
    } catch {
      checkController(false, "db controller gate should seed an in-memory message database: \(error.localizedDescription)")
      return
    }

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(false)
    let controller = MessageListAppKit(
      richTextTestBookPeerId: controllerPeer,
      chat: chat,
      db: appDb
    )
    let size = CGSize(width: 760, height: 420)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller

    defer {
      controller.dispose()
      window.contentViewController = nil
      window.close()
      for stableId in stableIds {
        calculator.debugClearRichBlockStateAndLayouts(for: stableId)
      }
      CacheAttrs.shared.invalidate()
      if let oldRichFlag {
        UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      } else {
        UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
      }
    }

    controller.debugPrepareRichTextControllerForTestBook(size: size)
    let fallbackSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      fallbackSnapshot.messageRowCount == richTexts.count,
      "db controller gate fallback should load every message row through MessagesProgressiveViewModel"
    )
    checkController(
      fallbackSnapshot.richRowCount == 0,
      "db controller gate fallback should not mount rich renderers while the feature flag is off"
    )
    checkController(
      fallbackSnapshot.fallbackRowCount == richTexts.count,
      "db controller gate fallback should mount fallback text for every DB-loaded message row"
    )
    checkController(
      fallbackSnapshot.constrainedRowCount == richTexts.count,
      "db controller gate fallback rows should keep active text slot constraints"
    )
    checkController(
      fallbackSnapshot.finiteHeightCount == fallbackSnapshot.rowCount,
      "db controller gate fallback should compute finite heights for every row"
    )

    ExperimentalFeatureFlags.setRichTextMessagesEnabled(true)
    controller.debugRefreshRichTextControllerForTestBook()
    let richSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      richSnapshot.messageRowCount == richTexts.count,
      "db controller gate rich mode should keep every DB-loaded message row"
    )
    checkController(
      richSnapshot.richRowCount == richMessageCount,
      "db controller gate rich mode should mount rich renderers for every rich DB message row"
    )
    checkController(
      richSnapshot.fallbackRowCount == plainMessageCount,
      "db controller gate rich mode should keep fallback text only for plain DB message rows"
    )
    checkController(
      richSnapshot.constrainedRowCount == richTexts.count,
      "db controller gate rich mode should keep active text slot constraints on every DB message row"
    )
    checkController(
      richSnapshot.finiteHeightCount == richSnapshot.rowCount,
      "db controller gate rich mode should compute finite heights for every row"
    )
    checkController(
      richSnapshot.contentHeight > size.height,
      "db controller gate rich list should create enough DB-backed content to exercise scrolling"
    )
    checkController(
      richSnapshot.madeMessageCellCount >= richTexts.count,
      "db controller gate rich mode should create message cells through MessageListAppKit"
    )
    checkController(
      richSnapshot.rowHeightQueryCount >= richSnapshot.rowCount,
      "db controller gate rich mode should query row heights through MessageListAppKit"
    )

    controller.debugScrollRichTextControllerForTestBook(to: max(0, richSnapshot.rowCount - 1))
    let scrolledSnapshot = controller.debugRichTextControllerSnapshotForTestBook()
    checkController(
      scrolledSnapshot.scrollOffsetY >= 0,
      "db controller gate scroll should keep a valid non-negative scroll offset"
    )
    checkController(
      scrolledSnapshot.scrollOffsetY > 0,
      "db controller gate scroll should move within oversized rich DB content"
    )
    checkController(
      scrolledSnapshot.scrollOffsetY <= max(0, scrolledSnapshot.contentHeight - size.height) + 1,
      "db controller gate scroll should stay inside DB-backed document bounds"
    )
  }

  private mutating func validateLiveRowOffscreenVisualSmoke(
    durableRichText: RichMessage,
    peer: InlineKit.Peer
  ) -> String {
    let mediaRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "media" })?.message
      ?? durableRichText
    let rtlRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "rtl" })?.message
      ?? durableRichText
    let cases = [
      RichLiveRowVisualCase(
        label: "bubble rich media",
        richText: mediaRichText,
        renderStyle: .bubble,
        expectedRich: true,
        tableWidth: 720
      ),
      RichLiveRowVisualCase(
        label: "minimal rich collapsible",
        richText: durableRichText,
        renderStyle: .minimal,
        expectedRich: true,
        tableWidth: 720
      ),
      RichLiveRowVisualCase(
        label: "bubble rich rtl",
        richText: rtlRichText,
        renderStyle: .bubble,
        expectedRich: true,
        tableWidth: 520
      ),
      RichLiveRowVisualCase(
        label: "bubble plain fallback",
        richText: nil,
        renderStyle: .bubble,
        expectedRich: false,
        tableWidth: 720
      ),
      RichLiveRowVisualCase(
        label: "minimal plain fallback",
        richText: nil,
        renderStyle: .minimal,
        expectedRich: false,
        tableWidth: 720
      ),
    ]

    let baseMessageId: Int64 = 98_820_000
    var stats: [RichRendererVisualSnapshotStats] = []
    for (index, visualCase) in cases.enumerated() {
      let message = makeFullMessage(
        messageId: baseMessageId + Int64(index),
        stableId: baseMessageId + Int64(index),
        peer: peer,
        richText: visualCase.richText
      )
      defer {
        calculator.debugClearRichBlockStateAndLayouts(for: message.id)
      }

      let props = viewProps(
        for: message,
        renderStyle: visualCase.renderStyle,
        tableWidth: visualCase.tableWidth
      )
      let cell = makeTableCell(size: tableCellSize(for: props, tableWidth: visualCase.tableWidth))
      cell.configure(with: message, props: props, animate: false)
      cell.layoutSubtreeIfNeeded()
      guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
        checkVisualSmoke(false, "\(visualCase.label) should expose a row slot snapshot")
        continue
      }

      checkVisualSmoke(
        snapshot.usesRichBlockRenderer == visualCase.expectedRich,
        "\(visualCase.label) should \(visualCase.expectedRich ? "use" : "not use") the rich renderer"
      )
      checkVisualSmoke(
        snapshot.richViewAttached == visualCase.expectedRich,
        "\(visualCase.label) rich block attachment should match expected render mode"
      )
      checkVisualSmoke(
        snapshot.textViewAttached != visualCase.expectedRich,
        "\(visualCase.label) fallback text attachment should be opposite render mode"
      )
      checkVisualSmoke(
        snapshot.hasActiveTextSlotConstraints,
        "\(visualCase.label) should keep active text slot constraints"
      )

      guard let visualStats = offscreenLiveRowVisualSnapshot(for: cell, label: visualCase.label) else {
        continue
      }
      stats.append(visualStats)
      checkVisualSmoke(visualStats.isPassing, "visual smoke: \(visualStats.failureSummary)")
    }

    let passing = stats.filter(\.isPassing).count
    let details = stats.map(\.compactSummary).joined(separator: "; ")
    if details.isEmpty {
      return "visual smoke gate \(failures.isEmpty ? "ok" : "checked"), \(passing)/\(stats.count) row snapshot(s)"
    }
    return "visual smoke gate \(failures.isEmpty ? "ok" : "checked"), \(passing)/\(stats.count) row snapshot(s), \(details)"
  }

  private mutating func offscreenLiveRowVisualSnapshot(
    for cell: MessageTableCell,
    label: String
  ) -> RichRendererVisualSnapshotStats? {
    cell.layoutSubtreeIfNeeded()
    let width = ceil(cell.bounds.width)
    let height = ceil(cell.bounds.height)
    guard width >= 12, height >= 12 else {
      checkVisualSmoke(false, "\(label) layout is too small for visual smoke \(Int(width))x\(Int(height))")
      return nil
    }

    let snapshotHeight = min(height, 2400)
    let snapshotSize = CGSize(width: width, height: snapshotHeight)
    let host = NSView(frame: CGRect(origin: .zero, size: snapshotSize))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: snapshotSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    cell.frame = CGRect(origin: .zero, size: cell.bounds.size)
    host.addSubview(cell)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    cell.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    cell.displayIfNeeded()

    let snapshotRect = CGRect(origin: .zero, size: snapshotSize)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: snapshotRect) else {
      checkVisualSmoke(false, "\(label) could not allocate row visual smoke bitmap")
      return nil
    }
    rep.size = snapshotSize
    host.cacheDisplay(in: snapshotRect, to: rep)

    return RichRendererVisualSnapshotStats(
      label: label,
      pixelWidth: rep.pixelsWide,
      pixelHeight: rep.pixelsHigh,
      sample: RichRendererVisualSampler.sample(rep)
    )
  }

  private mutating func validateBubbleTimeStatusSnapshot(
    _ snapshot: RichMessageTimeStatusDebugSnapshot,
    layout: MessageSizeCalculator.LayoutPlans,
    time: MessageSizeCalculator.LayoutPlan,
    label: String
  ) {
    checkTimeStatus(!snapshot.hidden, "\(label) bubble time/status should be visible")
    checkTimeStatus(
      snapshot.trailingConstraintActive,
      "\(label) bubble time/status should use trailing placement"
    )
    checkTimeStatus(
      abs((snapshot.trailingConstraintConstant ?? 0) + time.spacing.right) < 0.5,
      "\(label) bubble time/status trailing constant should match deterministic layout"
    )
    checkTimeStatus(
      snapshot.frameInBubble.maxX <= layout.bubble.size.width + 0.5 &&
        snapshot.frameInBubble.maxY <= layout.bubble.size.height + 0.5,
      "\(label) mounted bubble time/status should fit inside the bubble"
    )

    if layout.placesTimeAboveReactions {
      checkTimeStatus(snapshot.topConstraintActive, "\(label) bubble time/status should use top placement")
      checkTimeStatus(!snapshot.bottomConstraintActive, "\(label) bubble time/status should not keep bottom placement")
      checkTimeStatus(
        abs((snapshot.topConstraintConstant ?? 0) - layout.timeViewTop) < 0.5,
        "\(label) bubble time/status top constant should match deterministic layout"
      )
      return
    }

    checkTimeStatus(snapshot.bottomConstraintActive, "\(label) bubble time/status should use bottom placement")
    checkTimeStatus(!snapshot.topConstraintActive, "\(label) bubble time/status should not keep top placement")
    checkTimeStatus(
      abs((snapshot.bottomConstraintConstant ?? 0) + time.spacing.bottom) < 0.5,
      "\(label) bubble time/status bottom constant should match deterministic layout"
    )
  }

  private mutating func validateMinimalTimeStatusSnapshot(
    _ snapshot: RichMessageTimeStatusDebugSnapshot,
    layout: MessageSizeCalculator.LayoutPlans,
    time: MessageSizeCalculator.LayoutPlan,
    label: String
  ) {
    checkTimeStatus(
      snapshot.frameInRow.minX >= -0.5 &&
        snapshot.frameInRow.minY >= -0.5 &&
        snapshot.frameInRow.maxX <= layout.wrapper.size.width + 0.5 &&
        snapshot.frameInRow.maxY <= layout.wrapper.size.height + 0.5,
      "\(label) mounted minimal time/status should fit inside the measured row"
    )

    if layout.hasName {
      checkTimeStatus(snapshot.centerYConstraintActive, "\(label) minimal time/status should align with sender name")
      checkTimeStatus(snapshot.leadingConstraintActive, "\(label) minimal time/status should use leading placement")
      checkTimeStatus(!snapshot.topConstraintActive, "\(label) minimal name time/status should not use top placement")
      checkTimeStatus(
        abs((snapshot.centerYConstraintConstant ?? 0) - MessageSizeCalculator.minimalInlineTimeVerticalOffset) < 0.5,
        "\(label) minimal time/status centerY constant should match deterministic layout"
      )
      checkTimeStatus(
        abs((snapshot.leadingConstraintConstant ?? 0) - time.spacing.left) < 0.5,
        "\(label) minimal time/status leading constant should match deterministic layout"
      )
      return
    }

    checkTimeStatus(snapshot.topConstraintActive, "\(label) minimal follow-up time/status should use top placement")
    checkTimeStatus(snapshot.trailingConstraintActive, "\(label) minimal follow-up time/status should use trailing placement")
    checkTimeStatus(
      abs((snapshot.topConstraintConstant ?? 0) -
        (layout.topMostContentTopSpacing + MessageSizeCalculator.minimalFollowUpTimeTopOffset)) < 0.5,
      "\(label) minimal time/status top constant should match deterministic layout"
    )
    checkTimeStatus(
      abs((snapshot.trailingConstraintConstant ?? 0) + time.spacing.left) < 0.5,
      "\(label) minimal time/status trailing constant should match deterministic layout"
    )
  }

  private mutating func cellSlotSnapshotForStateUpdate(
    _ cell: MessageTableCell,
    label: String
  ) -> RichTextSlotDebugSnapshot? {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
      checkStateUpdate(false, "\(label) should expose rich text slot snapshot")
      return nil
    }
    checkStateUpdate(snapshot.richViewAttached, "\(label) rich view should stay attached")
    checkStateUpdate(snapshot.hasActiveTextSlotConstraints, "\(label) should keep active constraints")
    return snapshot
  }

  private mutating func cellSlotSnapshotForDraftStreaming(
    _ cell: MessageTableCell,
    label: String
  ) -> RichTextSlotDebugSnapshot? {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
      checkDraftStreaming(false, "\(label) should expose rich text slot snapshot")
      return nil
    }
    checkDraftStreaming(snapshot.richViewAttached, "\(label) rich view should stay attached")
    checkDraftStreaming(snapshot.hasActiveTextSlotConstraints, "\(label) should keep active constraints")
    return snapshot
  }

  private mutating func validateStateUpdateInteraction(_ cell: MessageTableCell, label: String) {
    guard let snapshot = cell.debugRichTextInteractionSnapshotForTestBook() else {
      checkStateUpdate(false, "\(label) should expose row-mounted rich interaction snapshot")
      return
    }

    let copiedText = snapshot.copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
    checkStateUpdate(!copiedText.isEmpty, "\(label) row-mounted rich copy text should stay non-empty")
    checkStateUpdate(snapshot.copiedHasRTF, "\(label) row-mounted rich copy should keep RTF")

    let titleSet = Set(snapshot.contextMenuTitles)
    for requiredTitle in ["Select All Rich Text", "Copy Rich Message Text"] {
      checkStateUpdate(
        titleSet.contains(requiredTitle),
        "\(label) row-mounted rich menu should include \(requiredTitle)"
      )
    }
  }

  private mutating func validateDraftStreamingInteraction(_ cell: MessageTableCell, label: String) {
    guard let snapshot = cell.debugRichTextInteractionSnapshotForTestBook() else {
      checkDraftStreaming(false, "\(label) should expose row-mounted rich interaction snapshot")
      return
    }

    let copiedText = snapshot.copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
    checkDraftStreaming(!copiedText.isEmpty, "\(label) row-mounted rich copy text should stay non-empty")
    checkDraftStreaming(snapshot.copiedHasRTF, "\(label) row-mounted rich copy should keep RTF")
    checkDraftStreaming(snapshot.dragDidStart, "\(label) row-mounted drag selection should start")
    checkDraftStreaming(
      snapshot.dragSelectionDiagnostics.isPartialNonEmpty,
      "\(label) row-mounted drag selection should stay partial and non-empty: \(snapshot.dragSelectionDiagnostics.partialSummary)"
    )
    if snapshot.dragSelectionDiagnostics.visibleLeafCount > 2 {
      checkDraftStreaming(
        snapshot.dragSelectionDiagnostics.isPartialPassing,
        "\(label) row-mounted drag selection should stay cross-leaf on multi-block drafts: \(snapshot.dragSelectionDiagnostics.partialSummary)"
      )
    }
    checkDraftStreaming(
      !snapshot.dragSelectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      "\(label) row-mounted drag selection should keep selected text non-empty"
    )

    let titleSet = Set(snapshot.contextMenuTitles)
    for requiredTitle in ["Select All Rich Text", "Copy Rich Message Text"] {
      checkDraftStreaming(
        titleSet.contains(requiredTitle),
        "\(label) row-mounted rich menu should include \(requiredTitle)"
      )
    }
  }

  private mutating func validateDraftStreamingReuseDiagnostics(_ cell: MessageTableCell, label: String) {
    guard let diagnostics = cell.debugRichRendererReuseDiagnosticsForTestBook() else {
      checkDraftStreaming(false, "\(label) should expose row-mounted rich renderer reuse diagnostics")
      return
    }

    checkDraftStreaming(
      diagnostics.rootConfigures >= RichMessageTestFixtures.streamingDraftStages.count,
      "\(label) should configure the mounted rich renderer for every draft stage"
    )
    checkDraftStreaming(
      diagnostics.rootBlocksReused > 0,
      "\(label) should reuse the root rich blocks view across draft stages"
    )
    checkDraftStreaming(
      diagnostics.blockViewsReused > 0 || diagnostics.blockSignatureSkips > 0,
      "\(label) should reuse or skip stable block views across draft stages"
    )
    checkDraftStreaming(
      diagnostics.textViewsReused > 0 || diagnostics.blockSignatureSkips > 0,
      "\(label) should reuse TextKit leaves or skip unchanged text across draft stages"
    )
  }

  private mutating func validateTableCellSelectionInteraction(
    richMessage: FullMessage,
    props: MessageViewProps,
    label: String
  ) {
    seedMountedSelectionImageCache()
    let cell = makeTableCell(size: tableCellSize(for: props))
    cell.configure(with: richMessage, props: props, animate: false)
    validateCellSlot(cell, expectedRich: true, label: label)
    guard let snapshot = cell.debugRichTextInteractionSnapshotForTestBook() else {
      checkRowInteraction(false, "\(label) should expose row-mounted rich interaction snapshot")
      return
    }

    let copy = RichSelectionPasteboardSnapshot(text: snapshot.copiedText, hasRTF: snapshot.copiedHasRTF)
    checkRowInteraction(copy.isPassing, "\(label) should pass cross-block row copy gate: \(copy.summary)")
    validateRowDragSelection(snapshot, label: label)
    validateMenuTitles(snapshot.contextMenuTitles, label: label)
    validateRowContextCopyActions(
      snapshot.contextCopyActions,
      label: label,
      required: [
        ("Copy Link", "https://inline.chat", "link"),
        ("Copy Cell", "Selection should enter and leave the cell without swallowing vertical scroll.", "table cell"),
      ]
    )
    validateRowCopyableBlocks(
      snapshot.copyableBlocks,
      label: label,
      required: [
        ("Copy Code", "pasteboard.write(selected.plainText)", "code"),
      ]
    )
    validateRowMediaClickActions(snapshot.mediaClicks, label: label)
  }

  private func seedMountedSelectionImageCache() {
    guard let url = URL(string: "https://picsum.photos/seed/inline-selection-media/520/300") else { return }
    let request = ImageRequest(url: url)
    guard ImagePipeline.shared.cache.cachedImage(for: request) == nil else { return }

    let size = CGSize(width: 520, height: 300)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.systemIndigo.withAlphaComponent(0.28).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    NSColor.systemMint.withAlphaComponent(0.42).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 7
    path.move(to: CGPoint(x: 0, y: size.height * 0.68))
    path.line(to: CGPoint(x: size.width * 0.36, y: size.height * 0.34))
    path.line(to: CGPoint(x: size.width, y: size.height * 0.56))
    path.stroke()
    image.unlockFocus()

    ImagePipeline.shared.cache.storeCachedImage(ImageContainer(image: image), for: request, caches: [.memory])
  }

  private mutating func validateCellRootInteraction(_ cell: MessageTableCell, label: String) {
    guard let snapshot = cell.debugRichTextInteractionSnapshotForTestBook() else {
      checkRowInteraction(false, "\(label) should expose row-mounted rich interaction snapshot")
      return
    }
    checkRowInteraction(!snapshot.copiedText.isEmpty, "\(label) row-mounted rich copy text should be non-empty")
    checkRowInteraction(snapshot.copiedHasRTF, "\(label) row-mounted rich copy should include RTF")
    validateMenuTitles(snapshot.contextMenuTitles, label: label)
    validateRowCopyableBlocks(
      snapshot.copyableBlocks,
      label: label,
      required: [
        ("Copy Formula", "E = mc^2", "formula"),
      ]
    )
  }

  private mutating func validateRowCopyableBlocks(
    _ snapshots: [RichCopyableBlockDebugSnapshot],
    label: String,
    required: [(title: String, expectedFragment: String, description: String)]
  ) {
    let failed = snapshots.filter { !$0.didCopyExpectedText }
    checkRowInteraction(
      failed.isEmpty,
      "\(label) row-mounted copyable block should write expected pasteboard text for \(failed.map(\.menuTitle).joined(separator: ", "))"
    )

    for item in required {
      let matching = snapshots.filter { $0.menuTitle == item.title }
      let didCopy = snapshots.contains { snapshot in
        snapshot.menuTitle == item.title && snapshot.copiedText.contains(item.expectedFragment)
      }
      checkRowInteraction(
        didCopy,
        "\(label) row-mounted copyable block should include \(item.description) payload via \(item.title)"
      )

      guard item.title == "Copy Code" else { continue }
      checkRowInteraction(
        matching.contains { $0.actionButtonExists },
        "\(label) row-mounted Copy Code button should exist"
      )
      checkRowInteraction(
        matching.contains { $0.actionButtonHitTested },
        "\(label) row-mounted Copy Code button should be the primary hit target"
      )
      checkRowInteraction(
        matching.contains { $0.didActionButtonCopyExpectedText && $0.actionButtonCopiedText.contains(item.expectedFragment) },
        "\(label) row-mounted Copy Code button should write the expected pasteboard text"
      )
    }
  }

  private mutating func validateRowMediaClickActions(
    _ snapshot: RichMediaClickDebugSnapshot,
    label: String
  ) {
    checkRowInteraction(
      snapshot.previewableImageCount > 0,
      "\(label) row-mounted media should include at least one previewable image"
    )
    checkRowInteraction(
      snapshot.primaryPreviewOnlyCount >= snapshot.previewableImageCount,
      "\(label) row-mounted image primary click should open Quick Look preview only"
    )
    checkRowInteraction(
      snapshot.quickLookPreparedImageCount >= snapshot.previewableImageCount,
      "\(label) row-mounted previewable image should prepare a Quick Look item URL"
    )
    checkRowInteraction(
      snapshot.quickLookPrepareFailureCount == 0,
      "\(label) row-mounted previewable image Quick Look item URL preparation should not fail"
    )
    checkRowInteraction(
      snapshot.primaryClickDispatchPreviewCount >= snapshot.previewableImageCount,
      "\(label) row-mounted image primary click should dispatch to Quick Look preview"
    )
    checkRowInteraction(
      snapshot.primaryClickDispatchSourceOpenCount == 0,
      "\(label) row-mounted image primary click dispatch must not open source URL"
    )
    checkRowInteraction(
      snapshot.primaryClickClosesPreviewPanelCount == 0,
      "\(label) row-mounted image primary click must present/update Quick Look, not close an already visible preview"
    )
    checkRowInteraction(
      snapshot.primarySourceOpenCount == 0,
      "\(label) row-mounted image primary click must not open source URL"
    )
    checkRowInteraction(
      snapshot.imagePrimaryHitTargetCount >= snapshot.imageMediaViewCount,
      "\(label) row-mounted rich image should remain the topmost primary hit target"
    )
    checkRowInteraction(
      snapshot.imagePrimaryHitTargetMissCount == 0,
      "\(label) row-mounted rich image primary hit target should not be stolen by an overlay"
    )
    checkRowInteraction(
      snapshot.nonImagePrimaryPreviewCount == 0,
      "\(label) row-mounted non-image media must not use image Quick Look as the primary action"
    )
  }

  private mutating func validateRowContextCopyActions(
    _ snapshots: [RichContextCopyActionDebugSnapshot],
    label: String,
    required: [(title: String, expected: String, description: String)]
  ) {
    let failed = snapshots.filter { !$0.didCopyExpectedText }
    checkRowInteraction(
      failed.isEmpty,
      "\(label) row-mounted context copy should write expected pasteboard text for \(failed.map(\.menuTitle).joined(separator: ", "))"
    )

    for item in required {
      let matching = snapshots.filter { snapshot in
        snapshot.menuTitle == item.title && snapshot.copiedText == item.expected
      }
      let didCopy = snapshots.contains { snapshot in
        snapshot.menuTitle == item.title && snapshot.copiedText == item.expected
      }
      checkRowInteraction(
        didCopy,
        "\(label) row-mounted context copy should include \(item.description) payload via \(item.title)"
      )

      guard item.title == "Copy Cell" else { continue }
      checkRowInteraction(
        matching.contains { $0.source == "tableCellBackground" },
        "\(label) row-mounted Copy Cell should be provided by table cell background"
      )
      checkRowInteraction(
        matching.contains { $0.source == "tableCellBackground" && $0.sourceHitTested },
        "\(label) row-mounted Copy Cell background should be the primary hit target from padding, hit \(matching.map(\.sourceHitView).joined(separator: ", "))"
      )
    }
  }

  private mutating func validateMenuTitles(_ titles: [String], label: String) {
    let titleSet = Set(titles)
    for requiredTitle in ["Select All Rich Text", "Copy Rich Message Text"] {
      checkRowInteraction(
        titleSet.contains(requiredTitle),
        "\(label) row-mounted rich menu should include \(requiredTitle)"
      )
    }
  }

  private mutating func validateRowDragSelection(_ snapshot: RichTextInteractionDebugSnapshot, label: String) {
    checkRowInteraction(snapshot.dragDidStart, "\(label) row-mounted drag selection should start")
    checkRowInteraction(
      snapshot.dragSelectionDiagnostics.isPartialPassing,
      "\(label) row-mounted drag selection should be partial and cross-leaf: \(snapshot.dragSelectionDiagnostics.partialSummary)"
    )

    let expectedMarkers = [
      "Table cell text",
      "Nested quote paragraph",
      "Details child paragraph",
      "Thinking child paragraph",
      "Media caption selection",
    ]
    let missingMarkers = expectedMarkers.filter { !snapshot.dragSelectedText.contains($0) }
    checkRowInteraction(
      missingMarkers.isEmpty,
      "\(label) row-mounted drag selection should include fixture markers: missing \(missingMarkers.joined(separator: ", "))"
    )
  }

  private mutating func validateRowMountedSpoilerHitTargets(peer: InlineKit.Peer) {
    guard let spoilerRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "spoilers" })?.message else {
      checkRowSpoiler(false, "row-mounted spoiler fixture should exist")
      return
    }
    guard let linkRichText = RichMessageTestFixtures.samples.first(where: { $0.id == "links" })?.message else {
      checkRowSpoiler(false, "row-mounted spoiler link fixture should exist")
      return
    }

    let baseMessageId: Int64 = 98_806_000
    for (index, renderStyle) in MessageRenderStyle.allCases.enumerated() {
      let spoilerMessage = makeFullMessage(
        messageId: baseMessageId + Int64(index * 2),
        stableId: baseMessageId + Int64(index * 2),
        peer: peer,
        richText: spoilerRichText
      )
      validateRowSpoilerDiagnostics(
        richMessage: spoilerMessage,
        renderStyle: renderStyle,
        label: "\(renderStyle.title.lowercased()) row spoiler",
        mode: .hiddenSpoilers
      )

      let linkMessage = makeFullMessage(
        messageId: baseMessageId + Int64(index * 2 + 1),
        stableId: baseMessageId + Int64(index * 2 + 1),
        peer: peer,
        richText: linkRichText
      )
      validateRowSpoilerDiagnostics(
        richMessage: linkMessage,
        renderStyle: renderStyle,
        label: "\(renderStyle.title.lowercased()) row spoiler link",
        mode: .hiddenSpoilerLink
      )
    }
  }

  private enum RowSpoilerDiagnosticMode {
    case hiddenSpoilers
    case hiddenSpoilerLink
  }

  private mutating func validateRowSpoilerDiagnostics(
    richMessage: FullMessage,
    renderStyle: MessageRenderStyle,
    label: String,
    mode: RowSpoilerDiagnosticMode
  ) {
    let props = viewProps(for: richMessage, renderStyle: renderStyle)
    let cell = makeTableCell(size: tableCellSize(for: props))
    cell.configure(with: richMessage, props: props, animate: false)
    validateCellSlot(cell, expectedRich: true, label: label)

    guard let snapshot = cell.debugRichTextInteractionSnapshotForTestBook() else {
      checkRowSpoiler(false, "\(label) should expose row-mounted rich interaction snapshot")
      return
    }

    let diagnostics = snapshot.spoilerDiagnostics
    switch mode {
    case .hiddenSpoilers:
      checkRowSpoiler(diagnostics.spoilerRangeCount >= 2, "\(label) should expose spoiler ranges")
      checkRowSpoiler(
        diagnostics.hiddenRangeCount == diagnostics.spoilerRangeCount && diagnostics.revealedRangeCount == 0,
        "\(label) should keep every spoiler hidden initially: \(diagnostics.compactSummary)"
      )
      checkRowSpoiler(
        diagnostics.spoilerHitTargetCount == diagnostics.spoilerRangeCount && diagnostics.spoilerHitTargetMissCount == 0,
        "\(label) should resolve every hidden spoiler from row-mounted hit targets: \(diagnostics.compactSummary)"
      )
    case .hiddenSpoilerLink:
      checkRowSpoiler(diagnostics.hiddenLinkRangeCount > 0, "\(label) should expose a hidden spoiler link")
      checkRowSpoiler(
        diagnostics.spoilerHitTargetCount == diagnostics.spoilerRangeCount && diagnostics.spoilerHitTargetMissCount == 0,
        "\(label) should resolve hidden spoiler-link spoiler hit targets: \(diagnostics.compactSummary)"
      )
      checkRowSpoiler(
        diagnostics.linkHitTargetCount >= diagnostics.hiddenLinkRangeCount &&
          diagnostics.hiddenLinkRevealPriorityCount >= diagnostics.hiddenLinkRangeCount,
        "\(label) should resolve both spoiler and link for reveal-before-open: \(diagnostics.compactSummary)"
      )
    }
  }

  private func restoreRichFlag(_ oldRichFlag: Any?) {
    if let oldRichFlag {
      UserDefaults.standard.set(oldRichFlag, forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    } else {
      UserDefaults.standard.removeObject(forKey: ExperimentalFeatureFlags.richTextMessagesKey)
    }
  }

  private mutating func cellSlotSnapshot(
    _ cell: MessageTableCell,
    label: String
  ) -> RichTextSlotDebugSnapshot? {
    cell.layoutSubtreeIfNeeded()
    guard let snapshot = cell.debugRichTextSlotSnapshotForTestBook() else {
      check(false, "\(label) should expose a row slot snapshot")
      return nil
    }
    return snapshot
  }

  private func makeTableCell(size: CGSize) -> MessageTableCell {
    let cell = MessageTableCell(frame: NSRect(origin: .zero, size: size))
    cell.translatesAutoresizingMaskIntoConstraints = true
    return cell
  }

  private func tableCellSize(for props: MessageViewProps, tableWidth: CGFloat = 720) -> CGSize {
    CGSize(width: tableWidth, height: max(44, ceil(props.layout.totalHeight)))
  }

  private mutating func validateSlot(
    _ snapshot: RichTextSlotDebugSnapshot,
    expectedRich: Bool,
    label: String
  ) {
    check(
      snapshot.usesRichBlockRenderer == expectedRich,
      "\(label) should \(expectedRich ? "use" : "not use") the rich block renderer"
    )
    check(
      snapshot.richViewAttached == expectedRich,
      "\(label) rich block view attachment should match renderer mode"
    )
    check(
      snapshot.textViewAttached != expectedRich,
      "\(label) fallback text view attachment should be opposite renderer mode"
    )
    check(snapshot.hasActiveTextSlotConstraints, "\(label) should keep active text slot constraints")
  }

  private func viewProps(
    for message: FullMessage,
    renderStyle: MessageRenderStyle,
    tableWidth: CGFloat = 720
  ) -> MessageViewProps {
    let input = props(renderStyle: renderStyle)
    let layout = switch renderStyle {
    case .bubble:
      calculator.calculateBubbleSize(for: message, with: input, tableWidth: tableWidth).3
    case .minimal:
      calculator.calculateMinimalSize(for: message, with: input, tableWidth: tableWidth).3
    }
    return MessageViewProps(
      firstInGroup: input.firstInGroup,
      startsAfterDaySeparator: input.startsAfterDaySeparator,
      isLastMessage: input.isLastMessage,
      isFirstMessage: input.isFirstMessage,
      isRtl: input.isRtl,
      isDM: input.isDM,
      renderStyle: input.renderStyle,
      index: nil,
      translated: input.translated,
      interactionMode: input.interactionMode,
      replyThreadTitle: input.replyThreadTitle,
      layout: layout
    )
  }

  private func props(renderStyle: MessageRenderStyle) -> MessageViewInputProps {
    MessageViewInputProps(
      firstInGroup: true,
      startsAfterDaySeparator: false,
      isLastMessage: true,
      isFirstMessage: true,
      isDM: false,
      isRtl: false,
      translated: false,
      renderStyle: renderStyle,
      interactionMode: .normal,
      replyThreadTitle: nil
    )
  }

  private func applyDraft(
    draftId: String,
    peer: InlineKit.Peer,
    messageId: Int64,
    richText: RichMessage
  ) {
    var update = UpdateRichMessageDraft()
    update.draftID = draftId
    update.peerID = protocolPeer(peer)
    update.senderUserID = 98_760
    update.messageID = messageId
    update.richText = richText
    update.expiresAt = Int64(Date().addingTimeInterval(60).timeIntervalSince1970)
    _ = RichMessageDraftStore.shared.apply(update)
  }

  private func clearDraft(draftId: String, peer: InlineKit.Peer, messageId: Int64) {
    var update = UpdateRichMessageDraft()
    update.draftID = draftId
    update.peerID = protocolPeer(peer)
    update.messageID = messageId
    update.senderUserID = 98_760
    update.clear = true
    update.expiresAt = Int64(Date().addingTimeInterval(60).timeIntervalSince1970)
    _ = RichMessageDraftStore.shared.apply(update)
  }

  private func protocolPeer(_ peer: InlineKit.Peer) -> InlineProtocol.Peer {
    switch peer {
    case let .user(id):
      return InlineProtocol.Peer.with { $0.user.userID = id }
    case let .thread(id):
      return InlineProtocol.Peer.with { $0.chat.chatID = id }
    }
  }
}

private final class RichLiveRowTableHarness: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  struct Row {
    let message: FullMessage
    let props: MessageViewProps
    let expectedRich: Bool
    let label: String

    var height: CGFloat {
      max(44, ceil(props.layout.totalHeight))
    }
  }

  let tableView = NSTableView()
  private let scrollView = NSScrollView()
  private let tableWidth: CGFloat
  private let viewportHeight: CGFloat
  private var rows: [Row] = []
  private(set) var renderedViewCount = 0

  init(tableWidth: CGFloat, viewportHeight: CGFloat = 420) {
    self.tableWidth = tableWidth
    self.viewportHeight = viewportHeight
    super.init()
    configureTableView()
  }

  func load(_ rows: [Row]) {
    self.rows = rows
    let totalHeight = max(44, rows.reduce(CGFloat.zero) { $0 + $1.height })
    scrollView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: min(totalHeight, viewportHeight))
    tableView.frame = NSRect(x: 0, y: 0, width: tableWidth, height: totalHeight)
    tableView.tableColumns.first?.width = tableWidth
    tableView.reloadData()
    scrollView.contentView.scroll(to: .zero)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    if !rows.isEmpty {
      tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }
    tableView.layoutSubtreeIfNeeded()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    rows.count
  }

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard rows.indices.contains(row) else { return 44 }
    return rows[row].height
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    renderedViewCount += 1

    let rowSpec = rows[row]
    let identifier = NSUserInterfaceItemIdentifier("RichLiveRowTableHarnessMessageCell")
    let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? MessageTableCell
      ?? MessageTableCell(frame: NSRect(x: 0, y: 0, width: tableWidth, height: rowSpec.height))
    cell.identifier = identifier
    cell.frame = NSRect(x: 0, y: 0, width: tableWidth, height: rowSpec.height)
    cell.configure(with: rowSpec.message, props: rowSpec.props, animate: false)
    cell.layoutSubtreeIfNeeded()
    return cell
  }

  func cell(at row: Int) -> MessageTableCell? {
    tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? MessageTableCell
  }

  func scrollRowToVisible(_ row: Int) {
    tableView.scrollRowToVisible(row)
    scrollView.reflectScrolledClipView(scrollView.contentView)
    tableView.layoutSubtreeIfNeeded()
  }

  func visibleRowIndexes() -> [Int] {
    let range = tableView.rows(in: tableView.visibleRect)
    guard range.location != NSNotFound, range.length > 0 else { return [] }
    return Array(range.location..<(range.location + range.length))
      .filter { rows.indices.contains($0) }
  }

  private func configureTableView() {
    scrollView.documentView = tableView
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false

    tableView.style = .plain
    tableView.backgroundColor = .clear
    tableView.headerView = nil
    tableView.rowSizeStyle = .custom
    tableView.selectionHighlightStyle = .none
    tableView.allowsMultipleSelection = false
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
    tableView.usesAutomaticRowHeights = false
    tableView.rowHeight = 44
    tableView.delegate = self
    tableView.dataSource = self

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("messageColumn"))
    column.isEditable = false
    column.resizingMask = []
    column.width = tableWidth
    tableView.addTableColumn(column)
  }
}

private struct RichDeterministicLayoutGate {
  private let style: RichMessageBlockStyle
  private var checkedLayouts = 0
  private var checkedBlocks = 0
  private var failures: [String] = []

  init(style: RichMessageBlockStyle) {
    self.style = style
  }

  mutating func report() -> RichDeterministicLayoutGateReport {
    let messages =
      RichMessageTestFixtures.samples.map(\.message)
        + RichMessageTestFixtures.streamingDraftStages
        + RichMessageTestFixtures.rendererReuseStressStages

    for (messageIndex, message) in messages.enumerated() {
      for width in [CGFloat(320), CGFloat(520), CGFloat(760), CGFloat(920)] {
        let plan = layout(message, width: width, state: .initial)
        checkedLayouts += 1
        validatePlan(plan, label: "message \(messageIndex) width \(Int(width))")
      }
    }

    let mediaSummary = validateMediaExamples()
    validateTableExamples()
    let codeSummary = validateCodeExamples()
    let tableWheelBehaviorSummary = validateTableWheelRouting()
    validateExpansionStateExamples()
    let structuralSummary = validateStructuralExamples()

    return RichDeterministicLayoutGateReport(
      checkedLayouts: checkedLayouts,
      checkedBlocks: checkedBlocks,
      structuralSummary: structuralSummary,
      mediaSummary: mediaSummary,
      codeSummary: codeSummary,
      tableWheelBehaviorSummary: tableWheelBehaviorSummary,
      failures: failures
    )
  }

  private mutating func validateExpansionStateExamples() {
    guard let collapsibleMessage = RichMessageTestFixtures.samples.first(where: { $0.id == "collapsible" })?.message,
          let quoteMessage = RichMessageTestFixtures.samples.first(where: { $0.id == "quotes" })?.message
    else {
      failures.append("state gate: required collapsible fixtures are missing")
      return
    }

    validateExpansionState(
      message: collapsibleMessage,
      id: "thinking",
      collapsedState: .initial,
      expandedState: RichMessageBlockStateSnapshot(overrides: ["thinking": true]),
      width: 520,
      label: "thinking"
    )

    validateExpansionState(
      message: collapsibleMessage,
      id: "details",
      collapsedState: RichMessageBlockStateSnapshot(overrides: ["details": false]),
      expandedState: RichMessageBlockStateSnapshot(overrides: ["details": true]),
      width: 520,
      label: "details"
    )

    validateExpansionState(
      message: quoteMessage,
      id: "quotes.collapsed",
      collapsedState: .initial,
      expandedState: RichMessageBlockStateSnapshot(overrides: ["quotes.collapsed": true]),
      width: 520,
      label: "expandable quote"
    )
  }

  private mutating func validateExpansionState(
    message: RichMessage,
    id: String,
    collapsedState: RichMessageBlockStateSnapshot,
    expandedState: RichMessageBlockStateSnapshot,
    width: CGFloat,
    label: String
  ) {
    let collapsed = layout(message, width: width, state: collapsedState)
    let expanded = layout(message, width: width, state: expandedState)
    checkedLayouts += 2
    validatePlan(collapsed, label: "\(label) collapsed")
    validatePlan(expanded, label: "\(label) expanded")

    let collapsedItem = firstItem(id: id, in: collapsed.root)
    let expandedItem = firstItem(id: id, in: expanded.root)

    guard let collapsedItem, let expandedItem else {
      failures.append("\(label): state gate could not find layout item")
      return
    }

    if let collapsedQuote = collapsedItem.quoteLayout, let expandedQuote = expandedItem.quoteLayout {
      validateRect(collapsedQuote.childFrame, label: "\(label) collapsed quote child")
      validateRect(expandedQuote.childFrame, label: "\(label) expanded quote child")
      if expandedQuote.childFrame.height <= collapsedQuote.childFrame.height + 0.5 {
        failures.append("\(label): expanded quote child height should exceed collapsed preview height")
      }
      if expandedItem.frame.height <= collapsedItem.frame.height + 0.5 {
        failures.append("\(label): expanded height should exceed collapsed height")
      }
      return
    }

    if collapsedItem.collapsibleLayout?.childFrame != nil {
      failures.append("\(label): collapsed state should not include child frame")
    }
    guard let expandedChildFrame = expandedItem.collapsibleLayout?.childFrame else {
      failures.append("\(label): expanded state should include child frame")
      return
    }
    validateRect(expandedChildFrame, label: "\(label) expanded child")
    if expandedItem.frame.height <= collapsedItem.frame.height + 0.5 {
      failures.append("\(label): expanded height should exceed collapsed height")
    }
  }

  private func layout(
    _ message: RichMessage,
    width: CGFloat,
    state: RichMessageBlockStateSnapshot
  ) -> RichMessageLayoutPlan {
    RichMessageBlockSizeCalculator.layout(
      for: message,
      width: width,
      style: style,
      state: state
    )
  }

  private func firstItem(id: String, in layout: RichBlocksLayoutPlan) -> RichBlockLayoutItem? {
    for item in layout.items {
      if item.id == id {
        return item
      }
      for child in item.children.values {
        if let match = firstItem(id: id, in: child) {
          return match
        }
      }
    }
    return nil
  }

  private mutating func validateStructuralExamples() -> String {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      checks += 1
      if !condition() {
        failures.append("structural: \(message)")
      }
    }

    guard let basics = sampleMessage(id: "basics"),
          let checklists = sampleMessage(id: "checklists"),
          let quotes = sampleMessage(id: "quotes"),
          let rtl = sampleMessage(id: "rtl")
    else {
      failures.append("structural: required fixture messages are missing")
      return "structural \(checks) check(s), missing fixtures"
    }

    let wideBasics = layout(basics, width: 920, state: .initial)
    checkedLayouts += 1
    validatePlan(wideBasics, label: "structural basics width cap")
    check(
      wideBasics.size.width <= RichMessageBlockSizeCalculator.maxContentWidth + 0.5,
      "root content should stay within max content width"
    )

    if let divider = firstItem(id: "basics.divider", in: wideBasics.root) {
      check(divider.frame.height > 0 && divider.frame.height <= 10, "divider should keep a subtle fixed height")
    } else {
      failures.append("structural: divider fixture is missing")
    }

    let checklistPlan = layout(checklists, width: 520, state: .initial)
    checkedLayouts += 1
    validatePlan(checklistPlan, label: "structural checklist insets")
    validateListMetrics(
      itemID: "checklists.unordered",
      in: checklistPlan.root,
      expectedMarkerWidth: 20,
      expectedCheckedStates: [false, true, nil],
      checks: &checks
    )
    validateListMetrics(
      itemID: "checklists.ordered",
      in: checklistPlan.root,
      expectedMarkerWidth: 61,
      expectedCheckedStates: [false, true],
      checks: &checks
    )

    var plainBullet = RichListBlock()
    plainBullet.ordered = false
    plainBullet.items = [RichListItemBlock()]
    let plainBulletMetrics = RichMessageBlockSizeCalculator.listMetrics(for: plainBullet, width: 320)
    check(approximately(plainBulletMetrics.markerWidth, 16), "plain bullet marker width should stay compact")
    check(
      approximately(plainBulletMetrics.childX, plainBulletMetrics.markerWidth + plainBulletMetrics.markerGap),
      "plain bullet child inset should be marker width plus gap"
    )

    let collapsedQuotes = layout(quotes, width: 520, state: .initial)
    let expandedQuotes = layout(
      quotes,
      width: 520,
      state: RichMessageBlockStateSnapshot(overrides: ["quotes.collapsed": true])
    )
    checkedLayouts += 2
    validatePlan(collapsedQuotes, label: "structural collapsed quote")
    validatePlan(expandedQuotes, label: "structural expanded quote")
    if let collapsed = firstItem(id: "quotes.collapsed", in: collapsedQuotes.root),
       let expanded = firstItem(id: "quotes.collapsed", in: expandedQuotes.root),
       let collapsedLayout = collapsed.quoteLayout,
       let expandedLayout = expanded.quoteLayout
    {
      check(approximately(collapsedLayout.ruleFrame.width, 3), "quote rule width should match renderer constant")
      check(collapsedLayout.childFrame.minX > collapsedLayout.ruleFrame.maxX, "quote child should be inset after rule")
      check(expandedLayout.childFrame.height > collapsedLayout.childFrame.height + 0.5, "expanded quote child height should grow")
      check(expanded.frame.height > collapsed.frame.height + 0.5, "expanded quote frame height should grow")
    } else {
      failures.append("structural: quote fixture layout is missing")
    }

    let rtlPlan = layout(rtl, width: 620, state: .initial)
    checkedLayouts += 1
    validatePlan(rtlPlan, label: "structural rtl blocks")
    check(rtl.direction == .directionLtr, "RTL fixture should keep wrapper LTR and rely on block direction")
    for id in ["rtl.rtl", "rtl.list", "rtl.quote", "rtl.table", "rtl.table.wide", "rtl.photo"] {
      guard let item = firstItem(id: id, in: rtlPlan.root) else {
        failures.append("structural: missing RTL block \(id)")
        continue
      }
      check(item.node.block.direction == .directionRtl, "\(id) should keep explicit block-level RTL direction")
    }

    return "structural \(checks) check(s)"
  }

  private func sampleMessage(id: String) -> RichMessage? {
    RichMessageTestFixtures.samples.first(where: { $0.id == id })?.message
  }

  private mutating func validateListMetrics(
    itemID: String,
    in layout: RichBlocksLayoutPlan,
    expectedMarkerWidth: CGFloat,
    expectedCheckedStates: [Bool?],
    checks: inout Int
  ) {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      checks += 1
      if !condition() {
        failures.append("structural: \(message)")
      }
    }

    guard let item = firstItem(id: itemID, in: layout),
          case let .list(list)? = item.node.block.block
    else {
      failures.append("structural: list fixture \(itemID) is missing")
      return
    }

    let metrics = RichMessageBlockSizeCalculator.listMetrics(for: list, width: item.frame.width)
    check(approximately(metrics.markerWidth, expectedMarkerWidth), "\(itemID) marker width should stay synced")
    check(
      approximately(metrics.childX, metrics.markerWidth + metrics.markerGap),
      "\(itemID) child inset should be marker width plus gap"
    )
    check(metrics.childWidth > 0 && metrics.childWidth < item.frame.width, "\(itemID) child width should fit inside block")
    check(list.items.count == expectedCheckedStates.count, "\(itemID) expected checklist fixture item count")
    for (index, expected) in expectedCheckedStates.enumerated() where index < list.items.count {
      let item = list.items[index]
      switch expected {
      case let .some(value):
        check(item.hasChecked && item.checked == value, "\(itemID) item \(index) checked state should be \(value)")
      case .none:
        check(!item.hasChecked, "\(itemID) item \(index) should remain a plain list item")
      }
    }
  }

  private mutating func validatePlan(_ plan: RichMessageLayoutPlan, label: String) {
    validateSize(plan.size, label: "\(label) root size")
    if plan.size.width > RichMessageBlockSizeCalculator.maxContentWidth + 0.5 {
      failures.append("\(label): root width exceeds max content width")
    }
    validateBlocks(plan.root, label: label)
  }

  private mutating func validateBlocks(_ layout: RichBlocksLayoutPlan, label: String) {
    validateSize(layout.size, label: "\(label) block stack")

    for item in layout.items {
      checkedBlocks += 1
      let itemLabel = "\(label) \(item.id)"
      validateRect(item.frame, label: itemLabel)
      if item.frame.minX < -0.5 || item.frame.minY < -0.5 ||
        item.frame.maxX > layout.size.width + 0.5 ||
        item.frame.maxY > layout.size.height + 0.5
      {
        failures.append("\(itemLabel): frame escapes parent layout")
      }

      if let mediaLayout = item.mediaLayout {
        validateMediaLayout(mediaLayout, label: itemLabel)
      }
      if let embedLayout = item.embedLayout {
        let (hasPoster, hasCaption) = switch item.node.block.block {
        case let .embed(block)?:
          (block.hasPoster, !block.caption.renderedPlainText.isEmpty)
        default:
          (false, false)
        }
        validateEmbedLayout(embedLayout, hasPoster: hasPoster, hasCaption: hasCaption, label: itemLabel)
      }
      if let embedPostLayout = item.embedPostLayout {
        let (hasAuthorPhoto, hasBlocks, hasCaption) = switch item.node.block.block {
        case let .embedPost(block)?:
          (block.hasAuthorPhoto, !block.blocks.isEmpty, !block.caption.renderedPlainText.isEmpty)
        default:
          (false, false, false)
        }
        validateEmbedPostLayout(
          embedPostLayout,
          hasAuthorPhoto: hasAuthorPhoto,
          hasBlocks: hasBlocks,
          hasCaption: hasCaption,
          label: itemLabel
        )
      }
      if let linkPreviewLayout = item.linkPreviewLayout {
        let hasMedia = switch item.node.block.block {
        case let .linkPreview(block)?:
          block.hasMedia
        default:
          false
        }
        validateLinkPreviewLayout(linkPreviewLayout, hasMedia: hasMedia, label: itemLabel)
      }
      if let tableLayout = item.tableLayout {
        validateTableLayout(tableLayout, label: itemLabel)
      }
      if let quoteLayout = item.quoteLayout {
        validateRect(quoteLayout.ruleFrame, label: "\(itemLabel) quote rule")
        validateRect(quoteLayout.childFrame, label: "\(itemLabel) quote child")
        if let buttonFrame = quoteLayout.buttonFrame {
          validateRect(buttonFrame, label: "\(itemLabel) quote button")
        }
      }
      if let collapsibleLayout = item.collapsibleLayout {
        validateRect(collapsibleLayout.buttonFrame, label: "\(itemLabel) collapsible button")
        if let childFrame = collapsibleLayout.childFrame {
          validateRect(childFrame, label: "\(itemLabel) collapsible child")
        }
      }

      if case let .code(code)? = item.node.block.block {
        let codeLayout = RichMessageBlockSizeCalculator.codeLayout(for: code, width: item.frame.width, style: style)
        validateCodeLayout(
          codeLayout,
          hasLanguage: code.hasLanguage && !code.language.isEmpty,
          label: itemLabel
        )
      }

      for (childKey, childLayout) in item.children {
        validateBlocks(childLayout, label: "\(itemLabel).\(childKey)")
      }
    }
  }

  private mutating func validateCodeExamples() -> String {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      checks += 1
      if !condition() {
        failures.append("code layout: \(message)")
      }
    }

    var longToken = RichCodeBlock()
    longToken.language = "swift"
    longToken.text = "let generatedIdentifier = \"inline_rich_text_code_block_layout_must_wrap_extremely_long_unbroken_tokens_without_clipping_or_autolayout\""
    let compact = RichMessageBlockSizeCalculator.codeLayout(for: longToken, width: 260, style: style)
    checkedLayouts += 1
    validateCodeLayout(compact, hasLanguage: true, label: "long token code")
    let lineHeight = max(1, ceil(style.codeFont.ascender - style.codeFont.descender + style.codeFont.leading))
    check(compact.textFrame.height >= lineHeight * 2, "unbroken long token should wrap to multiple measured lines")
    check(approximately(compact.size.width, 260), "compact code layout should keep requested width")

    var noLanguage = RichCodeBlock()
    noLanguage.text = "copyWithoutLanguage()"
    let noLanguageLayout = RichMessageBlockSizeCalculator.codeLayout(for: noLanguage, width: 320, style: style)
    checkedLayouts += 1
    validateCodeLayout(noLanguageLayout, hasLanguage: false, label: "code without language")
    check(noLanguageLayout.languageFrame == nil, "code without language should not reserve language label frame")

    return "code \(checks) check(s)"
  }

  private mutating func validateCodeLayout(
    _ layout: RichCodeLayoutPlan,
    hasLanguage: Bool,
    label: String
  ) {
    validateSize(layout.size, label: "\(label) code layout")
    validateRect(layout.copyFrame, label: "\(label) copy button")
    validateRect(layout.textFrame, label: "\(label) code text")

    if layout.copyFrame.maxX > layout.size.width + 0.5 || layout.copyFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): code copy button escapes block")
    }
    if layout.textFrame.maxX > layout.size.width + 0.5 || layout.textFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): code text escapes block")
    }
    if layout.copyFrame.intersects(layout.textFrame) {
      failures.append("\(label): code copy button overlaps text")
    }

    if hasLanguage {
      guard let languageFrame = layout.languageFrame else {
        failures.append("\(label): code language label frame is missing")
        return
      }
      validateRect(languageFrame, label: "\(label) language")
      if languageFrame.maxX > layout.size.width + 0.5 || languageFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): code language label escapes block")
      }
      if languageFrame.intersects(layout.copyFrame.insetBy(dx: -2, dy: 0)) {
        failures.append("\(label): code language label overlaps copy button")
      }
    } else if layout.languageFrame != nil {
      failures.append("\(label): code language label exists for unlabeled block")
    }
  }

  private mutating func validateMediaExamples() -> String {
    var checks = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      checks += 1
      if !condition() {
        failures.append("media sizing: \(message)")
      }
    }

    var compact = RichMediaRef()
    compact.width = 96
    compact.height = 64
    compact.media = .publicURL("https://example.com/compact.png")
    let compactLayout = RichMessageBlockSizeCalculator.mediaLayout(
      for: compact,
      caption: [],
      width: 520,
      style: style
    )
    checkedLayouts += 1
    validateMediaLayout(compactLayout, label: "compact media")
    check(approximately(compactLayout.mediaFrame.width, 96), "compact media should keep original width")
    check(approximately(compactLayout.mediaFrame.height, 64), "compact media should keep original height")
    check(approximately(compactLayout.size.width, 96), "compact media layout should not fill available width")

    let captionedCompactLayout = RichMessageBlockSizeCalculator.mediaLayout(
      for: compact,
      caption: [richText("caption")],
      width: 520,
      style: style
    )
    checkedLayouts += 1
    validateMediaLayout(captionedCompactLayout, label: "captioned compact media")
    check(approximately(captionedCompactLayout.mediaFrame.width, 96), "caption should not force compact media upscale")
    check(approximately(captionedCompactLayout.mediaFrame.height, 64), "caption should preserve compact media height")
    check(
      approximately(captionedCompactLayout.captionFrame?.width ?? 0, captionedCompactLayout.mediaFrame.width),
      "caption width should stay locked to rendered media width"
    )

    var wide = RichMediaRef()
    wide.width = 1400
    wide.height = 700
    wide.media = .publicURL("https://example.com/wide.jpg")
    let wideLayout = RichMessageBlockSizeCalculator.mediaLayout(
      for: wide,
      caption: [richText("caption")],
      width: 680,
      style: style
    )
    checkedLayouts += 1
    validateMediaLayout(wideLayout, label: "wide media")
    check(wideLayout.mediaFrame.width <= RichMessageBlockSizeCalculator.maxMediaSide + 0.5, "wide media width should stay capped")
    check(wideLayout.mediaFrame.height <= RichMessageBlockSizeCalculator.maxMediaHeight + 0.5, "wide media height should stay capped")
    check(approximately(wideLayout.mediaFrame.width / wideLayout.mediaFrame.height, 2, tolerance: 0.02), "wide media aspect ratio should be preserved")

    var unknown = RichMediaRef()
    unknown.media = .publicURL("https://example.com/unknown.jpg")
    let unknownLayout = RichMessageBlockSizeCalculator.mediaLayout(
      for: unknown,
      caption: [],
      width: 680,
      style: style
    )
    checkedLayouts += 1
    validateMediaLayout(unknownLayout, label: "unknown-size media")
    check(
      unknownLayout.mediaFrame.width <= RichMessageBlockSizeCalculator.fallbackMediaSize.width + 0.5,
      "unknown-size media should use fallback width instead of filling the row"
    )
    check(
      approximately(
        unknownLayout.mediaFrame.width / unknownLayout.mediaFrame.height,
        RichMessageBlockSizeCalculator.fallbackMediaSize.width / RichMessageBlockSizeCalculator.fallbackMediaSize.height,
        tolerance: 0.02
      ),
      "unknown-size media should use fallback aspect ratio"
    )

    var poster = RichEmbedBlock()
    poster.provider = "Inline"
    poster.url = "https://example.com"
    poster.poster = compact
    let embedLayout = RichMessageBlockSizeCalculator.embedLayout(for: poster, width: 680, style: style)
    checkedLayouts += 1
    validateEmbedLayout(embedLayout, hasPoster: true, hasCaption: false, label: "compact embed poster")
    check(approximately(embedLayout.mediaFrame?.width ?? 0, 96), "embed poster should not upscale compact media")
    check(approximately(embedLayout.mediaFrame?.height ?? 0, 64), "embed poster should preserve compact media height")

    return "media sizing \(checks) check(s)"
  }

  private mutating func validateTableExamples() {
    var small = RichTableBlock()
    small.rows = [
      tableRow(["A", "B"]),
      tableRow(["1", "2"]),
    ]
    let smallLayout = RichMessageBlockSizeCalculator.tableLayout(for: small, width: 520, style: style)
    checkedLayouts += 1
    validateTableLayout(smallLayout, label: "compact table")
    if smallLayout.size.width >= 520 {
      failures.append("compact table: viewport should not fill available width")
    }

    var wide = RichTableBlock()
    wide.rows = [
      tableRow(["one", "two", "three", "four", "five", "six", "seven", "eight"]),
      tableRow(["start", "value", "long value", "scroll", "without", "vertical", "event", "capture"]),
    ]
    let wideLayout = RichMessageBlockSizeCalculator.tableLayout(for: wide, width: 320, style: style)
    checkedLayouts += 1
    validateTableLayout(wideLayout, label: "wide table")
    if wideLayout.contentSize.width <= wideLayout.viewportSize.width {
      failures.append("wide table: content should exceed viewport")
    }
    if wideLayout.viewportSize.height <= wideLayout.contentSize.height {
      failures.append("wide table: viewport should reserve horizontal scroller height")
    }
  }

  private mutating func validateTableWheelRouting() -> String {
    if RichTableWheelRouting.shouldHandleInTable(
      allowsHorizontalScroll: true,
      deltaX: 0,
      deltaY: 8,
      modifierFlags: []
    ) {
      failures.append("table wheel: vertical scroll should pass to parent")
    }

    if RichTableWheelRouting.shouldHandleInTable(
      allowsHorizontalScroll: false,
      deltaX: 8,
      deltaY: 0,
      modifierFlags: []
    ) {
      failures.append("table wheel: disabled horizontal scroll should pass to parent")
    }

    if !RichTableWheelRouting.shouldHandleInTable(
      allowsHorizontalScroll: true,
      deltaX: 8,
      deltaY: 0,
      modifierFlags: []
    ) {
      failures.append("table wheel: horizontal scroll should stay in table")
    }

    if !RichTableWheelRouting.shouldHandleInTable(
      allowsHorizontalScroll: true,
      deltaX: 0,
      deltaY: 8,
      modifierFlags: .shift
    ) {
      failures.append("table wheel: shift-wheel horizontal intent should stay in table")
    }

    let behavior = RichTableWheelRouting.debugBehaviorDiagnosticsForTestBook()
    if !behavior.isPassing {
      failures.append("table wheel: production scroll view behavior mismatch, \(behavior.compactSummary)")
    }

    return behavior.compactSummary
  }

  private mutating func validateMediaLayout(_ layout: RichMediaLayoutPlan, label: String) {
    validateSize(layout.size, label: "\(label) media layout")
    validateRect(layout.mediaFrame, label: "\(label) media frame")
    if layout.mediaFrame.maxX > layout.size.width + 0.5 || layout.mediaFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): media frame escapes layout")
    }
    if let captionFrame = layout.captionFrame {
      validateRect(captionFrame, label: "\(label) caption frame")
      if captionFrame.maxX > layout.size.width + 0.5 || captionFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): caption frame escapes layout")
      }
    }
  }

  private mutating func validateEmbedLayout(
    _ layout: RichEmbedLayoutPlan,
    hasPoster: Bool,
    hasCaption: Bool,
    label: String
  ) {
    validateSize(layout.size, label: "\(label) embed layout")
    validateRect(layout.cardFrame, label: "\(label) embed card")
    if layout.cardFrame.maxX > layout.size.width + 0.5 || layout.cardFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): embed card escapes layout")
    }

    if let mediaFrame = layout.mediaFrame {
      validateRect(mediaFrame, label: "\(label) embed poster")
      if !hasPoster {
        failures.append("\(label): embed has poster frame without poster ref")
      }
      if mediaFrame.maxX > layout.size.width + 0.5 || mediaFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): embed poster escapes layout")
      }
      if mediaFrame.intersects(layout.cardFrame) {
        failures.append("\(label): embed poster overlaps card")
      }
    } else if hasPoster {
      failures.append("\(label): embed poster ref has no media frame")
    }

    if let captionFrame = layout.captionFrame {
      validateRect(captionFrame, label: "\(label) embed caption")
      if !hasCaption {
        failures.append("\(label): embed has caption frame without caption text")
      }
      if captionFrame.maxX > layout.size.width + 0.5 || captionFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): embed caption escapes layout")
      }
      if let mediaFrame = layout.mediaFrame, captionFrame.intersects(mediaFrame) {
        failures.append("\(label): embed caption overlaps poster")
      }
      if captionFrame.intersects(layout.cardFrame) {
        failures.append("\(label): embed caption overlaps card")
      }
    } else if hasCaption {
      failures.append("\(label): embed caption has no caption frame")
    }
  }

  private mutating func validateEmbedPostLayout(
    _ layout: RichEmbedPostLayoutPlan,
    hasAuthorPhoto: Bool,
    hasBlocks: Bool,
    hasCaption: Bool,
    label: String
  ) {
    validateSize(layout.size, label: "\(label) embed post layout")
    validateRect(layout.headerFrame, label: "\(label) embed post header")
    if layout.headerFrame.maxX > layout.size.width + 0.5 || layout.headerFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): embed post header escapes layout")
    }

    if let authorPhotoFrame = layout.authorPhotoFrame {
      validateRect(authorPhotoFrame, label: "\(label) embed post author photo")
      if !hasAuthorPhoto {
        failures.append("\(label): embed post has author photo frame without media ref")
      }
      if authorPhotoFrame.maxX > layout.size.width + 0.5 || authorPhotoFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): embed post author photo escapes layout")
      }
      if !layout.headerFrame.contains(authorPhotoFrame) {
        failures.append("\(label): embed post author photo is not inside header")
      }
    } else if hasAuthorPhoto {
      failures.append("\(label): embed post author photo ref has no media frame")
    }

    if let childFrame = layout.childFrame {
      validateRect(childFrame, label: "\(label) embed post child")
      if !hasBlocks {
        failures.append("\(label): embed post has child frame without child blocks")
      }
      if childFrame.maxX > layout.size.width + 0.5 || childFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): embed post child escapes layout")
      }
      if childFrame.intersects(layout.headerFrame) {
        failures.append("\(label): embed post child overlaps header")
      }
    } else if hasBlocks {
      failures.append("\(label): embed post child blocks have no child frame")
    }

    if let captionFrame = layout.captionFrame {
      validateRect(captionFrame, label: "\(label) embed post caption")
      if !hasCaption {
        failures.append("\(label): embed post has caption frame without caption text")
      }
      if captionFrame.maxX > layout.size.width + 0.5 || captionFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): embed post caption escapes layout")
      }
      if captionFrame.intersects(layout.headerFrame) {
        failures.append("\(label): embed post caption overlaps header")
      }
      if let childFrame = layout.childFrame, captionFrame.intersects(childFrame) {
        failures.append("\(label): embed post caption overlaps child")
      }
    } else if hasCaption {
      failures.append("\(label): embed post caption has no caption frame")
    }
  }

  private mutating func validateLinkPreviewLayout(
    _ layout: RichLinkPreviewLayoutPlan,
    hasMedia: Bool,
    label: String
  ) {
    validateSize(layout.size, label: "\(label) link preview layout")
    validateRect(layout.ruleFrame, label: "\(label) link preview rule")
    validateRect(layout.textFrame, label: "\(label) link preview text")
    if layout.ruleFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): link preview rule escapes layout")
    }
    if layout.textFrame.maxX > layout.size.width + 0.5 || layout.textFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): link preview text escapes layout")
    }

    guard let mediaFrame = layout.mediaFrame else {
      if hasMedia {
        failures.append("\(label): link preview media ref has no media frame")
      }
      return
    }

    validateRect(mediaFrame, label: "\(label) link preview media")
    if !hasMedia {
      failures.append("\(label): link preview has media frame without media ref")
    }
    if mediaFrame.maxX > layout.size.width + 0.5 || mediaFrame.maxY > layout.size.height + 0.5 {
      failures.append("\(label): link preview media escapes layout")
    }
    if mediaFrame.intersects(layout.textFrame) {
      failures.append("\(label): link preview media overlaps text")
    }
  }

  private mutating func validateTableLayout(_ layout: RichTableLayoutPlan, label: String) {
    validateSize(layout.size, label: "\(label) table layout")
    validateSize(layout.viewportSize, label: "\(label) table viewport")
    validateSize(layout.contentSize, label: "\(label) table content")
    if layout.viewportSize.width > layout.size.width + 0.5 || layout.viewportSize.height > layout.size.height + 0.5 {
      failures.append("\(label): viewport escapes table layout")
    }
    if layout.contentSize.width < layout.viewportSize.width - 0.5 {
      failures.append("\(label): content width is smaller than viewport")
    }
    for cell in layout.cells {
      validateRect(cell.frame, label: "\(label) cell \(cell.id)")
      validateRect(cell.textFrame, label: "\(label) cell text \(cell.id)")
      if cell.frame.maxX > layout.contentSize.width + 0.5 || cell.frame.maxY > layout.contentSize.height + 0.5 {
        failures.append("\(label): cell \(cell.id) escapes table content")
      }
      if cell.textFrame.maxX > cell.frame.maxX + 0.5 || cell.textFrame.maxY > cell.frame.maxY + 0.5 {
        failures.append("\(label): text for \(cell.id) escapes cell")
      }
    }
    if let captionFrame = layout.captionFrame {
      validateRect(captionFrame, label: "\(label) table caption")
      if captionFrame.maxX > layout.size.width + 0.5 || captionFrame.maxY > layout.size.height + 0.5 {
        failures.append("\(label): table caption escapes layout")
      }
    }
  }

  private mutating func validateSize(_ size: CGSize, label: String) {
    if !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 {
      failures.append("\(label): invalid size \(size.width)x\(size.height)")
    }
  }

  private mutating func validateRect(_ rect: CGRect, label: String) {
    if !rect.minX.isFinite || !rect.minY.isFinite ||
      !rect.width.isFinite || !rect.height.isFinite ||
      rect.width <= 0 || rect.height <= 0
    {
      failures.append("\(label): invalid rect \(rect)")
    }
  }

  private func tableRow(_ values: [String]) -> RichTableRow {
    var row = RichTableRow()
    row.cells = values.map { value in
      var cell = RichTableCell()
      cell.text = [richText(value)]
      return cell
    }
    return row
  }

  private func richText(_ value: String) -> RichText {
    var text = RichText()
    text.text = value
    return text
  }

  private func approximately(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 0.1) -> Bool {
    abs(lhs - rhs) <= tolerance
  }
}

private struct RichStreamingDraftTestCaseView: View {
  let style: RichMessageBlockStyle

  @State private var stage = 0
  @State private var autoCycling = false
  @State private var reuseDiagnostics = RichRendererReuseDiagnostics()

  private var stages: [RichMessage] {
    RichMessageTestFixtures.streamingDraftStages
  }

  private var reuseGatePassed: Bool {
    stage == 0 || (
      reuseDiagnostics.rootBlocksReused > 0 &&
        (reuseDiagnostics.textViewsReused > 0 || reuseDiagnostics.blockSignatureSkips > 0)
    )
  }

  private var reuseGateSummary: String {
    let status = stage == 0
      ? "Reuse gate: advance snapshots"
      : reuseGatePassed ? "Reuse gate ok" : "Reuse gate missing"
    return "\(status) - \(reuseDiagnostics.compactSummary)"
  }

  private var reuseGateColor: Color {
    if stage == 0 {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return reuseGatePassed ? Color(nsColor: .secondaryLabelColor) : .red
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Streaming draft snapshots")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        Text("\(stage + 1)/\(stages.count)")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.tertiary)

        Button {
          stage = max(0, stage - 1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(stage == 0)
        .help("Previous draft snapshot")

        Button {
          stage = min(stages.count - 1, stage + 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(stage == stages.count - 1)
        .help("Next draft snapshot")

        Button {
          stage = 0
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(stage == 0)
        .help("Reset draft snapshots")

        Button {
          runAutoCycle()
        } label: {
          Image(systemName: "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(autoCycling || stages.count <= 1)
        .help("Auto-cycle draft snapshots")
      }
      .frame(width: 544, alignment: .leading)

      Text(reuseGateSummary)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(reuseGateColor)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 544, alignment: .leading)

      RichMessageAppKitTestRenderer(
        richText: stages[stage],
        availableWidth: 520,
        style: style,
        reuseDiagnosticsRequest: stage,
        reuseDiagnosticsDidUpdate: { diagnostics in
          reuseDiagnostics = diagnostics
        }
      )
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func runAutoCycle() {
    guard !autoCycling, stages.count > 1 else { return }
    let lastIndex = stages.count - 1
    autoCycling = true
    stage = 0

    for index in 1...lastIndex {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.24) {
        stage = index
        if index == lastIndex {
          autoCycling = false
        }
      }
    }
  }
}

private struct RichRendererReuseStressTestCaseView: View {
  let style: RichMessageBlockStyle

  @State private var stage = 0
  @State private var autoCycling = false
  @State private var reuseDiagnostics = RichRendererReuseDiagnostics()

  private var stages: [RichMessage] {
    RichMessageTestFixtures.rendererReuseStressStages
  }

  private var missingReuseSurfaces: [String] {
    var missing: [String] = []
    if reuseDiagnostics.rootBlocksReused == 0 { missing.append("root") }
    if reuseDiagnostics.textViewsReused == 0 { missing.append("text") }
    if reuseDiagnostics.tableContainersReused == 0 { missing.append("table") }
    if reuseDiagnostics.mediaViewsReused == 0 { missing.append("media") }
    if reuseDiagnostics.chromeViewsReused == 0 { missing.append("chrome") }
    return missing
  }

  private var reuseGatePassed: Bool {
    stage == 0 || missingReuseSurfaces.isEmpty
  }

  private var reuseGateSummary: String {
    if stage == 0 {
      return "Reuse gate: advance snapshots - \(reuseDiagnostics.compactSummary)"
    }
    if reuseGatePassed {
      return "Reuse gate ok - \(reuseDiagnostics.compactSummary)"
    }
    return "Reuse gate missing \(missingReuseSurfaces.joined(separator: ", ")) - \(reuseDiagnostics.compactSummary)"
  }

  private var reuseGateColor: Color {
    if stage == 0 {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return reuseGatePassed ? Color(nsColor: .secondaryLabelColor) : .red
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Renderer reuse stress")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        Text("\(stage + 1)/\(stages.count)")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.tertiary)

        Button {
          stage = max(0, stage - 1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(stage == 0)
        .help("Previous renderer snapshot")

        Button {
          stage = min(stages.count - 1, stage + 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(stage == stages.count - 1)
        .help("Next renderer snapshot")

        Button {
          stage = 0
        } label: {
          Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(stage == 0)
        .help("Reset renderer snapshots")

        Button {
          runAutoCycle()
        } label: {
          Image(systemName: "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(autoCycling || stages.count <= 1)
        .help("Auto-cycle reuse snapshots")
      }
      .frame(width: 544, alignment: .leading)

      Text(reuseGateSummary)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(reuseGateColor)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(width: 544, alignment: .leading)

      RichMessageAppKitTestRenderer(
        richText: stages[stage],
        availableWidth: 520,
        style: style,
        reuseDiagnosticsRequest: stage,
        reuseDiagnosticsDidUpdate: { diagnostics in
          reuseDiagnostics = diagnostics
        }
      )
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func runAutoCycle() {
    guard !autoCycling, stages.count > 1 else { return }
    let lastIndex = stages.count - 1
    autoCycling = true
    stage = 0

    for index in 1...lastIndex {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.24) {
        stage = index
        if index == lastIndex {
          autoCycling = false
        }
      }
    }
  }
}

private struct RichMessageTestCaseView: View {
  let sample: RichMessageTestSample
  let style: RichMessageBlockStyle

  @State private var pasteboardSnapshot = RichSelectionPasteboardSnapshot.read()
  @State private var copyAllSelectionRequest = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(sample.title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)

        Spacer(minLength: 12)

        if sample.id == "selection" {
          RichSelectionPasteboardProbe(
            snapshot: pasteboardSnapshot,
            copyAll: {
              copyAllSelectionRequest += 1
            },
            refresh: {
              pasteboardSnapshot = .read()
            }
          )
        }
      }
      .frame(width: 544, alignment: .leading)

      RichMessageAppKitTestRenderer(
        richText: sample.message,
        availableWidth: 520,
        style: style,
        copyAllSelectionRequest: sample.id == "selection" ? copyAllSelectionRequest : 0,
        selectionDebugDidCopy: {
          pasteboardSnapshot = .read()
        }
      )
      .padding(12)
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct RichSelectionPasteboardProbe: View {
  let snapshot: RichSelectionPasteboardSnapshot
  let copyAll: () -> Void
  let refresh: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Text(snapshot.summary)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(snapshot.statusColor)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 280, alignment: .trailing)

      Button(action: copyAll) {
        Image(systemName: "selection.pin.in.out")
      }
      .buttonStyle(.borderless)
      .help("Select all rich text and copy from the production renderer")

      Button(action: refresh) {
        Image(systemName: "clipboard")
      }
      .buttonStyle(.borderless)
      .help("Refresh pasteboard preview")
    }
  }
}

private struct RichSelectionPasteboardSnapshot: Equatable {
  let text: String
  let hasRTF: Bool

  private var selectionFixtureMarkersInOrder: Bool {
    var searchStart = text.startIndex
    for marker in [
      "Selection stress fixture",
      "Drag from this paragraph",
      "let selected = richMessage.selection",
      "Table cell text",
      "Selection should enter and leave the cell",
      "Nested quote paragraph selected after the table.",
      "Details child paragraph selected after the quote.",
      "Thinking child paragraph selected after details.",
      "Media caption selection should work",
      "این متن باید در انتخاب ترکیبی پایدار بماند.",
    ] {
      guard let range = text.range(of: marker, range: searchStart..<text.endIndex) else {
        return false
      }
      searchStart = range.upperBound
    }
    return true
  }

  private var selectionPreservesIndentedCode: Bool {
    text.contains("\n    pasteboard.write(selected.plainText)")
  }

  var isPassing: Bool {
    selectionFixtureMarkersInOrder && selectionPreservesIndentedCode && hasRTF
  }

  var statusColor: Color {
    if text.isEmpty {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return isPassing ? Color(nsColor: .secondaryLabelColor) : .red
  }

  var summary: String {
    let kinds = hasRTF ? "plain + RTF" : "plain, missing RTF"
    let status = isPassing ? "copy gate ok, " : ""
    let fixture = selectionFixtureMarkersInOrder ? "fixture order ok, " : ""
    let indentation = selectionPreservesIndentedCode ? "indent ok, " : ""
    let preview = text
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !preview.isEmpty else { return "Pasteboard: \(kinds), empty text" }
    return "Pasteboard: \(status)\(fixture)\(indentation)\(kinds), \(String(preview.prefix(80)))"
  }

  static func read() -> Self {
    let pasteboard = NSPasteboard.general
    return RichSelectionPasteboardSnapshot(
      text: pasteboard.string(forType: .string) ?? "",
      hasRTF: pasteboard.data(forType: .rtf) != nil
    )
  }
}

private struct RichMessageAppKitTestRenderer: View {
  let richText: RichMessage
  let availableWidth: CGFloat
  let style: RichMessageBlockStyle
  var copyAllSelectionRequest = 0
  var selectionDebugDidCopy: (() -> Void)?
  var reuseDiagnosticsRequest = 0
  var reuseDiagnosticsDidUpdate: ((RichRendererReuseDiagnostics) -> Void)?

  @State private var state = RichMessageBlockStateSnapshot.initial

  var body: some View {
    let layout = RichMessageBlockSizeCalculator.layout(
      for: richText,
      width: availableWidth,
      style: style,
      state: state
    )
    RichMessageAppKitRepresentable(
      richText: richText,
      layout: layout,
      style: style,
      state: state,
      copyAllSelectionRequest: copyAllSelectionRequest,
      reuseDiagnosticsRequest: reuseDiagnosticsRequest,
      stateDidChange: { state = $0 },
      selectionDebugDidCopy: selectionDebugDidCopy,
      reuseDiagnosticsDidUpdate: reuseDiagnosticsDidUpdate
    )
    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
  }
}

private struct RichMessageAppKitRepresentable: NSViewRepresentable {
  let richText: RichMessage
  let layout: RichMessageLayoutPlan
  let style: RichMessageBlockStyle
  let state: RichMessageBlockStateSnapshot
  let copyAllSelectionRequest: Int
  let reuseDiagnosticsRequest: Int
  let stateDidChange: (RichMessageBlockStateSnapshot) -> Void
  let selectionDebugDidCopy: (() -> Void)?
  let reuseDiagnosticsDidUpdate: ((RichRendererReuseDiagnostics) -> Void)?

  final class Coordinator {
    var handledCopyAllSelectionRequest = 0
    var handledReuseDiagnosticsRequest: Int?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context _: Context) -> RichMessageBlockAppKitView {
    let view = RichMessageBlockAppKitView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = true
    return view
  }

  func updateNSView(_ view: RichMessageBlockAppKitView, context: Context) {
    view.frame = CGRect(origin: .zero, size: layout.size)
    view.configure(
      richText: richText,
      layout: layout,
      style: style,
      state: state,
      stateDidChange: stateDidChange
    )

    if context.coordinator.handledReuseDiagnosticsRequest != reuseDiagnosticsRequest {
      context.coordinator.handledReuseDiagnosticsRequest = reuseDiagnosticsRequest
      let diagnostics = view.debugReuseDiagnosticsForTestBook()
      DispatchQueue.main.async {
        reuseDiagnosticsDidUpdate?(diagnostics)
      }
    }

    if copyAllSelectionRequest != context.coordinator.handledCopyAllSelectionRequest {
      context.coordinator.handledCopyAllSelectionRequest = copyAllSelectionRequest
      view.debugSelectAllAndCopyRichTextForTestBook()
      DispatchQueue.main.async {
        selectionDebugDidCopy?()
      }
    }
  }
}

private struct RichMessageTestSample: Identifiable {
  let id: String
  let title: String
  let message: RichMessage
}

private enum RichMessageTestFixtures {
  static let streamingDraftStages: [RichMessage] = [
    message([
      thinking([
        paragraph([text("Searching recent context and deciding how much of the partial answer is stable enough to show.")], id: "draft.thinking.p0"),
      ], collapsed: false, id: "draft.thinking"),
      paragraph([
        text("I’m checking the current rendering path and preparing a compact answer."),
      ], id: "draft.visible.0"),
    ]),
    message([
      thinking([
        paragraph([text("Searching recent context and deciding how much of the partial answer is stable enough to show.")], id: "draft.thinking.p0"),
        paragraph([text("The durable message remains a stable anchor while this transient draft changes.")], id: "draft.thinking.p1"),
      ], collapsed: false, id: "draft.thinking"),
      paragraph([
        text("I’m checking the current rendering path and preparing a compact answer."),
      ], id: "draft.visible.0"),
      paragraph([
        text("The first result is that streaming updates should not reparse rich Markdown or resolve public media."),
      ], id: "draft.visible.1"),
    ]),
    message([
      thinking([
        paragraph([text("Searching recent context and deciding how much of the partial answer is stable enough to show.")], id: "draft.thinking.p0"),
        paragraph([text("The durable message remains a stable anchor while this transient draft changes.")], id: "draft.thinking.p1"),
        paragraph([text("Stable block IDs should preserve expansion, spoiler, and selection state while text grows.")], id: "draft.thinking.p2"),
      ], collapsed: false, id: "draft.thinking"),
      paragraph([
        text("I’m checking the current rendering path and preparing a compact answer."),
      ], id: "draft.visible.0"),
      paragraph([
        text("The first result is that streaming updates should not reparse rich Markdown or resolve public media."),
      ], id: "draft.visible.1"),
      paragraph([
        text("This fixture keeps the same renderer mounted while the draft snapshot changes so layout churn is visible."),
      ], id: "draft.visible.2"),
    ]),
    message([
      thinking([
        paragraph([text("Stable block IDs should preserve expansion, spoiler, and selection state while text grows.")], id: "draft.thinking.p2"),
        paragraph([text("Final delivery will replace this transient draft with a sanitized durable rich message.")], id: "draft.thinking.p3"),
      ], collapsed: true, id: "draft.thinking"),
      paragraph([
        text("Streaming should now feel stable: a durable anchor, transient thinking, paragraph-level visible drafts, and final full rich parsing only once."),
      ], id: "draft.visible.0"),
      paragraph([
        text("Drag selection across these paragraphs after cycling stages to check that reused TextKit leaves still copy in order."),
      ], id: "draft.visible.1"),
    ]),
  ]

  static let rendererReuseStressStages: [RichMessage] = [
    rendererReuseStressMessage(
      intro: "Initial card, media, table, and caption content.",
      previewTitle: "Renderer reuse phase one",
      previewDescription: "Link preview chrome should be created once, then reused.",
      tableStatus: "created",
      photoCaption: "Stable media URL with first caption.",
      detailsOpen: false
    ),
    rendererReuseStressMessage(
      intro: "Second snapshot updates text and captions but keeps stable block ids.",
      previewTitle: "Renderer reuse phase two",
      previewDescription: "The URL overlay, accent rule, and background should reuse in place.",
      tableStatus: "reused",
      photoCaption: "Stable media URL with edited caption text.",
      detailsOpen: false
    ),
    rendererReuseStressMessage(
      intro: "Third snapshot opens details and grows nested content without replacing stable children.",
      previewTitle: "Renderer reuse phase three",
      previewDescription: "Table containers, TextKit leaves, media, and card chrome should all show reuse.",
      tableStatus: "expanded",
      photoCaption: "Stable media URL with final caption text.",
      detailsOpen: true
    ),
  ]

  static let samples: [RichMessageTestSample] = [
    .init(
      id: "basics",
      title: "Text blocks, inline styles, lists, quotes, code, divider",
      message: message([
        heading("Rich text heading", level: 2, id: "basics.heading"),
        paragraph([
          text("Inline styles: "),
          text("bold", styles: [.styleBold]),
          text(", "),
          text("italic", styles: [.styleItalic]),
          text(", "),
          text("code", styles: [.styleCode]),
          text(", "),
          text("spoiler", styles: [.styleSpoiler]),
          text(", and "),
          text("links", styles: [.styleUnderline], url: "https://inline.chat"),
          text("."),
        ], id: "basics.paragraph"),
        list([
          [paragraph([text("First ordered item")], id: "basics.list.1.text")],
          [paragraph([text("Second item with nested explanation")], id: "basics.list.2.text")],
        ], ordered: true, id: "basics.list"),
        quote([
          paragraph([text("Expandable block quote with the first paragraph visible.")], id: "basics.quote.1"),
          paragraph([text("The rest appears after expansion.")], id: "basics.quote.2"),
        ], expandable: true, collapsed: true, id: "basics.quote"),
        code("const answer = await inline.richText.send(markdown);", language: "ts", id: "basics.code"),
        divider(id: "basics.divider"),
      ])
    ),
    .init(
      id: "collapsible",
      title: "Thinking, details, table, math, map",
      message: message([
        thinking([
          paragraph([text("Reasoning stays collapsed by default in chat but is inspectable in debug.")], id: "thinking.p"),
        ], collapsed: true, id: "thinking"),
        details(
          title: [text("Implementation notes")],
          blocks: [
            paragraph([text("Details are separate from thinking and can be opened independently.")], id: "details.p"),
          ],
          open: false,
          id: "details"
        ),
        table(
          rows: [
            [cell("Block", header: true), cell("Status", header: true), cell("Notes", header: true)],
            [cell("Paragraph"), cell("Ready"), cell("Inline entities")],
            [cell("Media"), cell("Beta"), cell("Public/CDN URLs and hydrated internal refs use native adapters")],
          ],
          id: "table"
        ),
        table(
          rows: [
            [cell("Area", header: true), cell("Phase", header: true), cell("Result", header: true)],
            [cell("Rowspan", rowspan: 2), cell("Measure"), cell("The first column spans two rows.")],
            [cell("Render"), cell("The second row should not overlap the spanned cell.")],
            [cell("Colspan summary", header: true, colspan: 3)],
          ],
          id: "table.spans"
        ),
        math("E = mc^2", fallback: "E = mc^2", id: "math"),
        map(title: "Inline HQ", address: "San Francisco", id: "map"),
      ])
    ),
    .init(
      id: "checklists",
      title: "Task lists and ordered checklist alignment",
      message: message([
        list([
          [paragraph([text("Unchecked task")], id: "checklists.unordered.1")],
          [paragraph([text("Completed task")], id: "checklists.unordered.2")],
          [paragraph([text("Plain bullet stays aligned with task rows")], id: "checklists.unordered.3")],
        ], ordered: false, checked: [false, true, nil], id: "checklists.unordered"),
        list([
          [paragraph([text("Write the plan")], id: "checklists.ordered.1")],
          [paragraph([text("Ship the renderer")], id: "checklists.ordered.2")],
        ], ordered: true, checked: [false, true], id: "checklists.ordered"),
      ])
    ),
    .init(
      id: "spoilers",
      title: "Spoiler spans",
      message: message([
        paragraph([
          text("Hidden: "),
          text("launch date", styles: [.styleSpoiler]),
          text(". Mixed styling: "),
          text("bold secret", styles: [.styleBold, .styleSpoiler]),
          text("."),
        ], id: "spoilers.paragraph"),
      ])
    ),
    .init(
      id: "links",
      title: "Links and text interactions",
      message: message([
        paragraph([
          text("Open "),
          text("Inline", url: "https://inline.chat"),
          text(", copy "),
          text("documentation", url: "https://docs.inline.chat"),
          text(", or email "),
          text("support", url: "mailto:support@inline.chat"),
          text("."),
        ], id: "links.paragraph"),
        paragraph([
          text("Spoiler first: "),
          text("hidden link label", styles: [.styleSpoiler], url: "https://inline.chat"),
          text(" should reveal before opening."),
        ], id: "links.spoiler"),
      ])
    ),
    .init(
      id: "selection",
      title: "Cross-block selection and copy",
      message: message([
        heading("Selection stress fixture", level: 3, id: "selection.heading"),
        paragraph([
          text("Drag from this paragraph through "),
          text("spoilers", styles: [.styleSpoiler]),
          text(", "),
          text("links", url: "https://inline.chat"),
          text(", code blocks, table cells, captions, details, thinking, and nested quote text."),
        ], id: "selection.intro"),
        code("""
        let selected = richMessage.selection
        if selected.hasRichText {
            pasteboard.write(selected.plainText)
        }
        """, language: "swift", id: "selection.code"),
        table(
          rows: [
            [cell("Surface", header: true), cell("Expected behavior", header: true)],
            [cell("Table cell text"), cell("Selection should enter and leave the cell without swallowing vertical scroll.")],
            [cell("Copy order"), cell("Selected text should follow the visual document order.")],
          ],
          id: "selection.table"
        ),
        quote([
          paragraph([text("Nested quote paragraph selected after the table.")], id: "selection.quote.1"),
          paragraph([text("Second nested paragraph checks newline boundaries.")], id: "selection.quote.2"),
        ], expandable: false, collapsed: false, id: "selection.quote"),
        details(title: [text("Expanded details")], blocks: [
          paragraph([text("Details child paragraph selected after the quote.")], id: "selection.details.1"),
        ], open: true, id: "selection.details"),
        thinking([
          paragraph([text("Thinking child paragraph selected after details.")], id: "selection.thinking.1"),
        ], collapsed: false, id: "selection.thinking"),
        photo(
          url: "https://picsum.photos/seed/inline-selection-media/520/300",
          alt: "Selection media",
          caption: [
            text("Media caption selection should work next to a native photo adapter."),
          ],
          id: "selection.photo"
        ),
        paragraph([
          text("RTL leaf inside the same selection surface: "),
          text("این متن باید در انتخاب ترکیبی پایدار بماند."),
        ], direction: .directionRtl, id: "selection.rtl"),
      ])
    ),
    .init(
      id: "quotes",
      title: "Collapsed and expanded blockquotes",
      message: message([
        quote([
          paragraph([text("Collapsed quote preview line.")], id: "quotes.collapsed.1"),
          paragraph([text("Hidden quote body line that appears after expanding.")], id: "quotes.collapsed.2"),
        ], expandable: true, collapsed: true, id: "quotes.collapsed"),
        quote([
          paragraph([text("Expanded quote with multiple paragraphs.")], id: "quotes.expanded.1"),
          paragraph([text("Second paragraph should keep the measured height in sync.")], id: "quotes.expanded.2"),
        ], expandable: false, collapsed: false, id: "quotes.expanded"),
      ])
    ),
    .init(
      id: "media",
      title: "Public URL media, link preview, embed, post, collage",
      message: message([
        photo(
          url: "https://picsum.photos/seed/inline-rich-text/900/520",
          alt: "Generated landscape",
          caption: [text("Photo block with public HTTPS URL.")],
          id: "media.photo"
        ),
        document(fileName: "rich-text-spec.pdf", caption: [text("Document placeholder with caption.")], id: "media.document"),
        audio(title: "Voice note", performer: "Local-only playback", duration: 42, caption: [text("Audio block uses the native AppKit row and cached local voices when available.")], id: "media.audio"),
        audio(
          title: "CDN voice note",
          performer: "Ownerless rich voice",
          duration: 2,
          caption: [text("CDN-backed voice refs should download into the voice cache and then play without a root message attachment.")],
          voiceID: 456,
          cdnURL: "https://upload.wikimedia.org/wikipedia/commons/c/c8/Example.ogg",
          mimeType: "audio/ogg",
          id: "media.audio.cdn"
        ),
        linkPreview(id: "media.link"),
        embed(provider: "YouTube", url: "https://youtube.com/watch?v=dQw4w9WgXcQ", id: "media.embed"),
        embedPost(id: "media.post"),
        collage(id: "media.collage"),
      ])
    ),
    .init(
      id: "rtl",
      title: "Per-block RTL direction",
      message: message([
        paragraph([text("This paragraph stays LTR.")], id: "rtl.ltr"),
        paragraph([text("این بلوک راست به چپ است.")], direction: .directionRtl, id: "rtl.rtl"),
        list([
          [paragraph([text("اولین مورد ارث بری جهت را بررسی می کند.")], id: "rtl.list.1")],
          [paragraph([text("مورد دوم با چک لیست راست چین می ماند.")], id: "rtl.list.2")],
        ], ordered: true, checked: [nil, true], direction: .directionRtl, id: "rtl.list"),
        quote([
          paragraph([text("نقل قول باید خط و دکمه را سمت راست نشان دهد.")], id: "rtl.quote.1"),
          paragraph([text("متن داخلی جهت را از بلوک نقل قول به ارث می برد.")], id: "rtl.quote.2"),
        ], expandable: true, collapsed: false, direction: .directionRtl, id: "rtl.quote"),
        table(
          rows: [
            [cell("ستون", header: true), cell("مقدار", header: true)],
            [cell("جهت"), cell("راست به چپ")],
            [cell("انتخاب متن"), cell("باید درست بماند")],
          ],
          direction: .directionRtl,
          id: "rtl.table"
        ),
        table(
          rows: [
            [
              cell("یک", header: true),
              cell("دو", header: true),
              cell("سه", header: true),
              cell("چهار", header: true),
              cell("پنج", header: true),
              cell("شش", header: true),
              cell("هفت", header: true),
              cell("هشت", header: true),
            ],
            [
              cell("شروع راست"),
              cell("مقدار"),
              cell("متن بلند"),
              cell("اسکرول"),
              cell("بدون بلعیدن"),
              cell("رویداد عمودی"),
              cell("باقی می ماند"),
              cell("سمت چپ"),
            ],
          ],
          direction: .directionRtl,
          id: "rtl.table.wide"
        ),
        photo(
          url: "https://picsum.photos/seed/inline-rtl-media/320/220",
          alt: "RTL image",
          caption: [text("کپشن و تصویر کوچک باید سمت راست تراز شوند.")],
          direction: .directionRtl,
          id: "rtl.photo"
        ),
      ], direction: .directionLtr)
    ),
  ]

  private static func message(_ blocks: [RichBlock], direction: RichDirection = .directionUnspecified) -> RichMessage {
    var message = RichMessage()
    message.version = 1
    message.blocks = blocks
    if direction != .directionUnspecified {
      message.direction = direction
    }
    message.fallbackText = blocks.enumerated()
      .map { $0.element.renderedFallbackText(index: $0.offset, depth: 0) }
      .joined(separator: "\n\n")
    return message
  }

  private static func rendererReuseStressMessage(
    intro: String,
    previewTitle: String,
    previewDescription: String,
    tableStatus: String,
    photoCaption: String,
    detailsOpen: Bool
  ) -> RichMessage {
    message([
      paragraph([text(intro)], id: "reuse.paragraph"),
      details(
        title: [text("Reusable nested details")],
        blocks: [
          paragraph([text("Nested details content keeps a stable child id while expansion changes.")], id: "reuse.details.p"),
        ],
        open: detailsOpen,
        id: "reuse.details"
      ),
      table(
        rows: [
          [cell("Surface", header: true), cell("State", header: true), cell("Expected", header: true)],
          [cell("TextKit leaf"), cell(tableStatus), cell("same paragraph/table cell views")],
          [cell("Table scroll"), cell(tableStatus), cell("same horizontal scroll container")],
          [cell("Chrome"), cell(tableStatus), cell("same card background and overlay views")],
        ],
        id: "reuse.table"
      ),
      photo(
        url: "https://picsum.photos/seed/inline-rich-reuse-stress/900/520",
        alt: "Reuse stress image",
        caption: [text(photoCaption)],
        id: "reuse.photo"
      ),
      linkPreview(
        title: previewTitle,
        description: previewDescription,
        id: "reuse.link"
      ),
      map(title: "Reusable map card", address: "San Francisco", id: "reuse.map"),
      embed(provider: "Inline", url: "https://inline.chat", id: "reuse.embed"),
    ])
  }

  private static func text(_ value: String, styles: [RichTextStyle] = [], url: String? = nil) -> RichText {
    var text = RichText()
    text.text = value
    text.styles = styles
    if let url {
      text.url = url
    }
    return text
  }

  private static func paragraph(_ text: [RichText], direction: RichDirection = .directionUnspecified, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    if direction != .directionUnspecified {
      block.direction = direction
    }
    var paragraph = RichParagraphBlock()
    paragraph.text = text
    block.block = .paragraph(paragraph)
    return block
  }

  private static func heading(_ value: String, level: Int32, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var heading = RichHeadingBlock()
    heading.level = level
    heading.text = [text(value)]
    block.block = .heading(heading)
    return block
  }

  private static func list(
    _ items: [[RichBlock]],
    ordered: Bool,
    checked: [Bool?] = [],
    direction: RichDirection = .directionUnspecified,
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    if direction != .directionUnspecified {
      block.direction = direction
    }
    var list = RichListBlock()
    list.ordered = ordered
    list.start = 1
    list.items = items.enumerated().map { index, blocks in
      var item = RichListItemBlock()
      item.blocks = blocks
      if index < checked.count, let checked = checked[index] {
        item.checked = checked
      }
      return item
    }
    block.block = .list(list)
    return block
  }

  private static func quote(
    _ blocks: [RichBlock],
    expandable: Bool,
    collapsed: Bool,
    direction: RichDirection = .directionUnspecified,
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    if direction != .directionUnspecified {
      block.direction = direction
    }
    var quote = RichQuoteBlock()
    quote.blocks = blocks
    quote.expandable = expandable
    quote.initiallyCollapsed = collapsed
    block.block = .quote(quote)
    return block
  }

  private static func code(_ value: String, language: String, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var code = RichCodeBlock()
    code.text = value
    code.language = language
    block.block = .code(code)
    return block
  }

  private static func divider(id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    block.block = .divider(RichDividerBlock())
    return block
  }

  private static func thinking(_ blocks: [RichBlock], collapsed: Bool, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var thinking = RichThinkingBlock()
    thinking.blocks = blocks
    thinking.initiallyCollapsed = collapsed
    block.block = .thinking(thinking)
    return block
  }

  private static func details(title: [RichText], blocks: [RichBlock], open: Bool, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var details = RichDetailsBlock()
    details.title = title
    details.blocks = blocks
    details.initiallyOpen = open
    block.block = .details(details)
    return block
  }

  private static func table(
    rows: [[RichTableCell]],
    direction: RichDirection = .directionUnspecified,
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    if direction != .directionUnspecified {
      block.direction = direction
    }
    var table = RichTableBlock()
    table.bordered = true
    table.striped = true
    table.rows = rows.map { cells in
      var row = RichTableRow()
      row.cells = cells
      return row
    }
    block.block = .table(table)
    return block
  }

  private static func cell(_ value: String, header: Bool = false, colspan: Int32 = 1, rowspan: Int32 = 1) -> RichTableCell {
    var cell = RichTableCell()
    cell.text = [text(value)]
    cell.header = header
    cell.colspan = colspan
    cell.rowspan = rowspan
    return cell
  }

  private static func math(_ source: String, fallback: String, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var math = RichMathBlock()
    math.source = source
    math.display = true
    math.fallback = fallback
    block.block = .math(math)
    return block
  }

  private static func map(title: String, address: String, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var map = RichMapBlock()
    map.title = title
    map.address = address
    map.latitude = 37.7749
    map.longitude = -122.4194
    map.zoom = 12
    block.block = .map(map)
    return block
  }

  private static func photo(
    url: String,
    alt: String,
    caption: [RichText],
    direction: RichDirection = .directionUnspecified,
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    if direction != .directionUnspecified {
      block.direction = direction
    }
    var ref = RichMediaRef()
    ref.alt = alt
    ref.width = 900
    ref.height = 520
    ref.media = .publicURL(url)
    var photo = RichPhotoBlock()
    photo.media = ref
    photo.caption = caption
    block.block = .photo(photo)
    return block
  }

  private static func document(fileName: String, caption: [RichText], id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var ref = RichMediaRef()
    ref.fileName = fileName
    ref.media = .documentID(123)
    var document = RichDocumentBlock()
    document.media = ref
    document.caption = caption
    block.block = .document(document)
    return block
  }

  private static func audio(
    title: String,
    performer: String,
    duration: Int32,
    caption: [RichText],
    voiceID: Int64 = 123,
    cdnURL: String? = nil,
    mimeType: String? = nil,
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var ref = RichMediaRef()
    if let cdnURL {
      ref.cdnURL = cdnURL
    }
    if let mimeType {
      ref.mimeType = mimeType
    }
    ref.media = .voiceID(voiceID)
    var audio = RichAudioBlock()
    audio.media = ref
    audio.title = title
    audio.performer = performer
    audio.duration = duration
    audio.caption = caption
    block.block = .audio(audio)
    return block
  }

  private static func linkPreview(
    title: String = "Rich text blocks",
    description: String = "Block-level rich messages with media, collapsibles, and fallbacks.",
    id: String
  ) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var preview = RichLinkPreviewBlock()
    preview.url = "https://core.telegram.org/bots/api#june-11-2026"
    preview.displayURL = "core.telegram.org"
    preview.siteName = "Telegram Bot API"
    preview.title = title
    preview.description_p = description
    preview.mediaAspectRatio = 16 / 9
    var media = RichMediaRef()
    media.alt = "Telegram Bot API rich text preview"
    media.width = 640
    media.height = 360
    media.media = .publicURL("https://picsum.photos/seed/inline-link-preview/640/360")
    preview.media = media
    block.block = .linkPreview(preview)
    return block
  }

  private static func embed(provider: String, url: String, id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var embed = RichEmbedBlock()
    embed.provider = provider
    embed.url = url
    var poster = RichMediaRef()
    poster.alt = "Embed poster"
    poster.width = 640
    poster.height = 360
    poster.media = .publicURL("https://picsum.photos/seed/inline-embed-poster/640/360")
    embed.poster = poster
    embed.caption = [text("Embeds are represented safely until dedicated web embed rendering is enabled.")]
    block.block = .embed(embed)
    return block
  }

  private static func embedPost(id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var post = RichEmbedPostBlock()
    post.author = "Inline"
    post.url = "https://inline.chat"
    var authorPhoto = RichMediaRef()
    authorPhoto.alt = "Inline author"
    authorPhoto.width = 160
    authorPhoto.height = 160
    authorPhoto.media = .publicURL("https://picsum.photos/seed/inline-embed-post-author/160/160")
    post.authorPhoto = authorPhoto
    post.blocks = [
      paragraph([text("Embedded posts can contain their own rich block subtree.")], id: "\(id).p"),
    ]
    block.block = .embedPost(post)
    return block
  }

  private static func collage(id: String) -> RichBlock {
    var block = RichBlock()
    block.blockID = id
    var collage = RichCollageBlock()
    collage.layout = .collageLayoutGrid
    collage.items = [
      photo(url: "https://picsum.photos/seed/inline-collage-a/420/260", alt: "First image", caption: [], id: "\(id).a"),
      photo(url: "https://picsum.photos/seed/inline-collage-b/420/260", alt: "Second image", caption: [], id: "\(id).b"),
    ]
    collage.caption = [text("Collage block with two public URL photo children.")]
    block.block = .collage(collage)
    return block
  }
}
#endif
