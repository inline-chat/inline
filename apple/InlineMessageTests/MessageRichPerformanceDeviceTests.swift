@testable import InlineIOS
@testable import InlineKit
import InlineProtocol
import InlineTheme
import Testing
import TextProcessing
import UIKit

@Suite("iOS rich message device performance", .serialized)
@MainActor
struct MessageRichPerformanceDeviceTests {
  @Test("The maximum supported table remains bounded and scrollable")
  func maximumTable() throws {
    var full = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    var source = ""
    var rows: [BlockTableRow] = []
    for row in 0 ..< 16 {
      var cells: [BlockText] = []
      for column in 0 ..< 16 {
        let text = "R\(row) C\(column)"
        cells.append(.with { $0.offset = Int64(source.utf16.count)
          $0.length = Int64(text.utf16.count)
        })
        source += text + "\n"
      }
      rows.append(.with { $0.cells = cells })
    }
    full.message.text = source
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [.with { $0.table.rows = rows }]
    }))
    let started = CACurrentMediaTime()
    let view = UIMessageView2(
      fullMessage: full, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    let created = CACurrentMediaTime()
    let payload = try #require(full.message.blockContentPayload)
    let attributed = try #require(view.attributedMessageText())
    let plan = try #require(RichBlockLayoutPlannerV2.shared.plan(
      content: payload.content,
      contentCacheSignature: payload.cacheSignature,
      contentByteCount: payload.byteCount,
      attributedText: attributed,
      availableWidth: 297.5 - 24,
      baseFontSize: UIFontMetrics(forTextStyle: .body).scaledValue(for: 17, compatibleWith: view.traitCollection),
      primaryColor: view.textColor,
      secondaryColor: MessageRichTextRenderer.secondaryColor(for: false),
      disclosureOverrides: [:]
    ))
    #expect(plan.nodes.count == 1)
    let planned = CACurrentMediaTime()
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    let bound = CACurrentMediaTime()
    view.layoutIfNeeded()
    let laidOut = CACurrentMediaTime()
    let elapsed = (laidOut - started) * 1_000
    #expect(view.bounds.height.isFinite && view.bounds.height > 0)
    #expect(view.messageLabel.textStorage.length == 0)
    func descendants(_ view: UIView) -> [UIView] {
      [view] + view.subviews.flatMap(descendants)
    }
    let scroll = try #require(descendants(view).compactMap { $0 as? UIScrollView }.first {
      !($0 is UITextView) && $0.contentSize.width > $0.bounds.width
    })
    scroll.setContentOffset(CGPoint(x: scroll.contentSize.width - scroll.bounds.width, y: 0), animated: false)
    scroll.layoutIfNeeded()
    #expect(scroll.contentOffset.x > 0)
    Attachment.record(String(elapsed), named: "message-v2-256-cell-table-cold-ms.txt")
    Attachment.record(
      "create,plan,bind,layout\n\((created - started) * 1_000),\((planned - created) * 1_000),\((bound - planned) * 1_000),\((laidOut - bound) * 1_000)",
      named: "message-v2-256-cell-table-phases-ms.csv"
    )
    let tableTextViews = NSHashTable<UITextView>.weakObjects()
    for case let textView as UITextView in descendants(scroll) {
      tableTextViews.add(textView)
    }
    #expect(tableTextViews.allObjects.count == 256)
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [.with { $0.table.rows = [.with { $0.cells = [rows[0].cells[0]] }] }]
    }))
    view.applySnapshot(full)
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    view.layoutIfNeeded()
    #expect(tableTextViews.allObjects.count <= 1)
    #expect(scroll.contentOffset.x >= -0.5)
    #expect(scroll.contentOffset.x <= max(0, scroll.contentSize.width - scroll.bounds.width) + 0.5)
    // Pooling the table host must release its children, even while the old
    // scroll viewport itself remains retained by this test.
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [.with { $0.paragraph.length = 5 }]
    }))
    view.applySnapshot(full)
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    view.layoutIfNeeded()
    #expect(tableTextViews.allObjects.isEmpty)
    view.cancelPendingGeometryTransitions()
  }

  @Test("A long mixed history reuses cells while scrolling")
  func mixedHistoryScroll() async throws {
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let database = AppDatabase.empty()
    let publisher = MessagesPublisher(database: database)
    let peer = Peer.user(id: 9_007)
    let scenarios = MessageView2PlaygroundFixtures.scenarios.filter {
      [10_001, 10_005, 10_006, 10_009, 10_010, 10_011].contains($0.id)
    }
    let rows = (1 ... 300).reversed().map { index -> FullMessage in
      var full = scenarios[index % scenarios.count].message
      full.message.globalId = Int64(800_000 + index)
      full.message.messageId = Int64(index)
      full.message.chatId = 9_007
      full.message.peerThreadId = nil
      full.message.peerUserId = 9_007
      full.message.date = full.message.date.addingTimeInterval(Double(index))
      return full
    }
    let model = MessagesSectionedViewModel(
      peer: peer, reversed: true,
      initialState: .init(
        messages: rows,
        loadedWindowMetadata: MessagesProgressiveViewModel.unknownLoadedWindowMetadata(for: rows)
      ),
      database: database, publisher: publisher
    )
    defer { model.dispose() }
    let started = CACurrentMediaTime()
    let list = MessagesCollectionView(
      peerId: peer, chatId: 9_007, spaceId: nil, isPreview: true,
      theme: ThemeManager.shared.snapshot(variant: .light),
      viewModel: model, messageViewImplementation: .v2
    )
    list.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
    controller.view.addSubview(list)
    list.layoutIfNeeded()
    Attachment.record(
      String((CACurrentMediaTime() - started) * 1_000),
      named: "message-v2-mixed-history-initial-ms.txt"
    )
    try await Task.sleep(for: .milliseconds(100))
    var durations: [Double] = []
    var visited: Set<Int64> = []
    for step in 0 ..< 120 {
      let start = CACurrentMediaTime()
      let maximum = max(0, list.contentSize.height - list.bounds.height - 400)
      let target = min(maximum, 400 + CGFloat(step) * 140)
      list.setContentOffset(CGPoint(x: 0, y: target), animated: false)
      list.layoutIfNeeded()
      durations.append((CACurrentMediaTime() - start) * 1_000)
      for cell in list.visibleCells.compactMap({ $0 as? MessageCollectionViewCell }) {
        let renderer = try #require(cell.messageView as? UIMessageView2)
        let full = try #require(cell.message)
        visited.insert(full.id)
        #expect(renderer.fullMessage == full)
        #expect(cell.transform == .identity)
        #expect(cell.frame.height.isFinite && cell.frame.height > 0)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(visited.count > 30)
    #expect(list.visibleCells.count < 20)
    Attachment.record(
      durations.map(String.init(describing:)).joined(separator: "\n"),
      named: "message-v2-mixed-history-scroll-ms.txt"
    )
    list.removeFromSuperview()
  }
}
