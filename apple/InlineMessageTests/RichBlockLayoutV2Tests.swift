@testable import InlineIOS
import InlineIOSUI
import InlineProtocol
import Testing
import UIKit

@Suite("iOS rich block geometry", .serialized)
@MainActor
struct RichBlockLayoutV2Tests {
  @Test("Short paragraphs keep natural width in either writing direction", arguments: [false, true])
  func compactParagraph(rtl: Bool) throws {
    let source = rtl ? "سلام دنیا" : "Hello world"
    let plan = try plan(source, blocks: [paragraph(source, rtl: rtl)])
    #expect(plan.size.width < 200)
    #expect(abs(plan.size.width - ceil(attributed(source).size().width)) <= 1)
    #expect(plan.nodes.count == 1)
    assertContained(plan)
  }

  @Test("Short RTL paragraphs align to the width determined by their siblings")
  func rtlSiblingAlignment() throws {
    let first = "سلام"
    let second = "این یک متن طولانی برای بررسی چیدمان است"
    let source = first + "\n" + second
    let firstBlock = paragraph(first, rtl: true)
    let secondBlock = InlineProtocol.Block.with {
      $0.paragraph = textRange(second)
      $0.paragraph.offset = Int64(first.utf16.count + 1)
      $0.paragraph.isRtl = true
    }
    let plan = try plan(source, blocks: [firstBlock, secondBlock])
    #expect(plan.nodes[0].frame.width < plan.nodes[1].frame.width)
    #expect(abs(plan.nodes[0].frame.maxX - plan.size.width) <= 0.5)
    #expect(abs(plan.nodes[1].frame.maxX - plan.size.width) <= 0.5)
    assertContained(plan)
  }

  @Test("A separator fits a compact bubble")
  func compactSeparator() throws {
    let source = "Short text"
    let plan = try plan(source, blocks: [paragraph(source), .with { $0.separator = .init() }])
    #expect(plan.size.width < 300)
    assertContained(plan)
  }

  @Test("Quotes include their insets without claiming a full viewport", arguments: [false, true])
  func compactQuote(rtl: Bool) throws {
    let source = rtl ? "نقل قول" : "A short quote"
    let quote = InlineProtocol.Block.with {
      $0.quote = .with {
        $0.isRtl = rtl
        $0.children = [paragraph(source, rtl: rtl)]
      }
    }
    let plan = try plan(source, blocks: [quote])
    #expect(plan.size.width < 250)
    let decoration = try #require(plan.nodes.first)
    let text = try #require(plan.nodes.last)
    #expect(decoration.frame.contains(text.frame))
    assertContained(plan)
  }

  @Test("Nested quote decorations stay inside the measured bubble")
  func nestedQuote() throws {
    let source = "Nested"
    let quote = InlineProtocol.Block.with {
      $0.quote.children = [.with { $0.quote.children = [paragraph(source)] }]
    }
    let plan = try plan(source, blocks: [quote])
    #expect(plan.size.width < 200)
    assertContained(plan)
  }

  @Test("Code owns a full-width viewport and retains horizontal overflow")
  func codeViewport() throws {
    let source = "let longName = \"" + String(repeating: "x", count: 100) + "\""
    let block = InlineProtocol.Block.with {
      $0.code.text = textRange(source)
      $0.code.language = "swift"
    }
    let plan = try plan(source, blocks: [block])
    #expect(plan.size.width == 300)
    guard case let .code(code) = try #require(plan.nodes.first).kind else {
      Issue.record("Expected a code node")
      return
    }
    #expect(code.contentWidth > 300)
    #expect(code.lineCount == 1)
    assertContained(plan)
  }

  @Test("Disclosures retain activity semantics and compact geometry", arguments: [false, true])
  func disclosureActivity(rtl: Bool) throws {
    let source = rtl ? "در حال بررسی" : "Reading files"
    let block = InlineProtocol.Block.with {
      $0.disclosure.summary = textRange(source)
      $0.disclosure.isRtl = rtl
      $0.disclosure.activityKind = .read
    }
    let plan = try plan(source, blocks: [block])
    let node = try #require(plan.nodes.first)
    guard case let .text(text) = node.kind,
          case let .disclosure(_, _, activity) = text.role
    else {
      Issue.record("Expected a disclosure node")
      return
    }
    #expect(activity == .read)
    #expect(node.frame.width < 250)
    let geometry = RichBlockDisclosureMetricsV2.layout(
      bounds: CGRect(origin: .zero, size: node.frame.size), isRTL: rtl, hasActivity: true
    )
    #expect(geometry.title.width > 0)
    #expect(geometry.activity != nil)
    assertContained(plan)
  }

  @Test("Disclosure accessories remain inside narrow layouts", arguments: [1, 6, 18, 25, 37, 80, 300])
  func narrowDisclosure(width: Int) {
    let bounds = CGRect(x: 0, y: 0, width: width, height: 24)
    for rtl in [false, true] {
      for activity in [false, true] {
        let layout = RichBlockDisclosureMetricsV2.layout(bounds: bounds, isRTL: rtl, hasActivity: activity)
        for frame in [layout.title, layout.chevron, layout.activity].compactMap(\.self) where !frame.isEmpty {
          #expect(bounds.contains(frame))
        }
        #expect(layout.title.width >= 1)
        #expect(layout.title.intersection(layout.chevron).isEmpty)
        if let icon = layout.activity {
          #expect(layout.title.intersection(icon).isEmpty)
          #expect(layout.chevron.intersection(icon).isEmpty)
        }
      }
    }
  }

  @Test("Natural text measurements contain actual UITextView rendering", arguments: [
    "A short paragraph.",
    "A longer paragraph with narrow words and a final line that must remain visible when the bubble is compacted.",
    "First line\nSecond line\n",
    "سلام به همه دوستان، این یک پیام فارسی برای بررسی اندازه و چیدمان متن است.",
    "English before فارسی در میان متن and English after.\nخط دوم برای بررسی اندازه.",
    "यह एक संदेश है जिसमें अलग-अलग अक्षर और संयुक्ताक्षर हैं।",
    "ข้อความภาษาไทยสำหรับตรวจสอบความสูงและการตัดบรรทัดของข้อความ",
    "日本語の文章と中文内容を表示して、文字の高さと改行を確認します。",
    "שלום לכולם, זהו טקסט בעברית לבדיקת גובה השורות.",
    "Text with 👨‍👩‍👧‍👦 emoji and e\u{301} combining marks.",
  ])
  func renderedTextFits(source: String) throws {
    let plan = try plan(source, blocks: [paragraph(source)])
    let node = try #require(plan.nodes.first)
    guard case let .text(text) = node.kind else {
      Issue.record("Expected a text node")
      return
    }
    let view = CodeBlockTextView(usingTextLayoutManager: false)
    view.isEditable = false
    view.isSelectable = false
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    let original = try #require(RichBlockLayoutPlannerV2.styledText(
      from: attributed(source), range: text.range, role: text.role, baseFontSize: 17, isRTL: text.isRTL
    ))
    view.attributedText = original
    view.frame = CGRect(origin: .zero, size: node.frame.size)
    view.layoutIfNeeded()
    let manager = view.layoutManager
    let container = view.textContainer
    manager.ensureLayout(for: container)
    var renderedHeight = manager.usedRect(for: container).maxY
    if manager.extraLineFragmentTextContainer === container {
      renderedHeight = max(renderedHeight, manager.extraLineFragmentRect.maxY)
    }
    #expect(manager.glyphRange(for: container).length == manager.numberOfGlyphs)
    let expectedHeight = max(ceil(17 * 1.25), ceil(renderedHeight))
    #expect(
      abs(expectedHeight - node.frame.height) <= 1,
      "Laid-out glyph height: \(renderedHeight), planned frame: \(node.frame)"
    )
  }

  @Test("Catalog geometry remains contained at larger text sizes", arguments: [17, 23, 34, 53])
  func catalogAtTextSize(fontSize: Int) throws {
    for scenario in MessageView2PlaygroundFixtures.scenarios {
      guard let payload = scenario.message.message.blockContentPayload else { continue }
      let source = scenario.message.message.text ?? ""
      let plan = try #require(RichBlockLayoutPlannerV2.shared.plan(
        content: payload.content,
        contentCacheSignature: payload.cacheSignature,
        contentByteCount: payload.byteCount,
        attributedText: attributed(source),
        availableWidth: 280,
        baseFontSize: CGFloat(fontSize),
        disclosureOverrides: [:]
      ))
      #expect(plan.size.width <= 280)
      #expect(plan.size.height.isFinite && plan.size.height > 0)
      assertContained(plan)
    }
  }

  private func plan(_ source: String, blocks: [InlineProtocol.Block]) throws -> RichBlockLayoutPlanV2 {
    let content = InlineProtocol.BlockContent.with { $0.blocks = blocks }
    let bytes = try content.serializedData()
    return try #require(RichBlockLayoutPlannerV2.shared.plan(
      content: content, contentCacheSignature: bytes.hashValue, contentByteCount: bytes.count,
      attributedText: attributed(source), availableWidth: 300, baseFontSize: 17, disclosureOverrides: [:]
    ))
  }

  private func paragraph(_ source: String, rtl: Bool = false) -> InlineProtocol.Block {
    .with {
      $0.paragraph = textRange(source)
      $0.paragraph.isRtl = rtl
    }
  }

  private func textRange(_ source: String) -> InlineProtocol.BlockText {
    .with { $0.length = Int64(source.utf16.count) }
  }

  private func attributed(_ source: String) -> NSAttributedString {
    NSAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 17)])
  }

  private func assertContained(_ plan: RichBlockLayoutPlanV2, sourceLocation: SourceLocation = #_sourceLocation) {
    let bounds = CGRect(origin: .zero, size: plan.size).insetBy(dx: -0.5, dy: -0.5)
    for node in plan.nodes {
      #expect(
        bounds.contains(node.frame),
        "Block \(node.path) extends outside its plan",
        sourceLocation: sourceLocation
      )
    }
  }
}
