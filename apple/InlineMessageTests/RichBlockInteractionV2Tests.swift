@testable import InlineIOS
import InlineKit
import InlineProtocol
import InlineTheme
import InlineUI
import Testing
import TextProcessing
import UIKit

@Suite("iOS rich entity interaction", .serialized)
@MainActor
struct RichBlockInteractionV2Tests {
  @Test("Ready rich images decode, open the selected occurrence, and clear on reuse")
  func readyImagePresentation() async throws {
    let id = Int64.random(in: 8_000_000_000_000 ... 9_000_000_000_000)
    let photo = InlineProtocol.Photo.with {
      $0.id = id
      $0.format = .png
      $0.sizes = [.with { $0.type = "f"
        $0.w = 64
        $0.h = 64
        $0.size = 256
        $0.cdnURL = "https://example.invalid/native-device-fixture.png"
      }]
    }
    let info = PhotoInfo(
      photo: InlineKit.Photo.from(proto: photo),
      sizes: photo.sizes.map { InlineKit.PhotoSize.from(proto: $0, photoId: photo.id) }
    )
    let url = try #require(FileCache.cachedLocalURL(photo: info, fileExists: { _ in true }))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bitmap = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    let data = try #require(bitmap.pngData())
    try data.write(to: url, options: .withoutOverwriting)
    // Exercise the real cache loader, then retain the generated artifact only
    // in temporary storage. This fixture never creates a database photo row.
    defer {
      do {
        let artifact = FileManager.default.temporaryDirectory.appendingPathComponent("message-v2-\(id).png")
        try FileManager.default.moveItem(at: url, to: artifact)
      } catch {
        Issue.record(error, "Could not move the generated image fixture to temporary storage")
      }
    }
    let alt = "Cached device image"
    let blockImage = BlockImage.with { $0.ready = photo
      $0.alt.length = Int64(alt.utf16.count)
    }
    let content = BlockContent.with {
      $0.blocks = [.with { $0.image = blockImage }, .with { $0.album.images = [blockImage] }]
    }
    let (view, _) = try richView(source: alt, content: content)
    let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    controller.view.addSubview(view)
    view.layoutIfNeeded()
    func descendants(_ root: UIView) -> [UIView] {
      [root] + root.subviews.flatMap(descendants)
    }
    let photos = descendants(view).compactMap { $0 as? PlatformPhotoView }
    #expect(photos.count == 2)
    for _ in 0 ..< 100 where photos.contains(where: { $0.displayedImage == nil }) {
      try await Task.sleep(for: .milliseconds(20))
      view.layoutIfNeeded()
    }
    #expect(photos.allSatisfy { $0.displayedImage != nil })
    #expect(view.readyImageOccurrences.count == 2)
    var selections: [BlockContentPath] = []
    view.onImageTap = {
      #expect($0.sourceImage != nil)
      #expect($0.sourceView.window != nil)
      selections.append($0.image.path)
    }
    for node in descendants(view) where node.accessibilityLabel == alt && node.accessibilityTraits.contains(.button) {
      #expect(node.accessibilityActivate())
    }
    #expect(Set(selections).count == 2)
    view.prepareForReuse()
    #expect(view.readyImageOccurrences.isEmpty)
    #expect(photos.allSatisfy { $0.displayedImage == nil })
  }

  @Test("Image descriptions and formula copy targets preserve canonical source")
  func imageDescriptionsAndMathSource() throws {
    let alt = "👩🏽‍💻 System diagram"
    let formula = #"\frac{x^2}{y}"#
    let source = alt + "\n" + formula
    let content = BlockContent.with {
      $0.blocks = [
        .with {
          $0.image.alt.length = Int64(alt.utf16.count)
          $0.image.pending.dimensions = .with { $0.width = 120
            $0.height = 80
          }
        },
        .with {
          $0.album.images = [.with {
            $0.alt.length = Int64(alt.utf16.count)
            $0.unavailable.dimensions = .with { $0.width = 120
              $0.height = 80
            }
          }]
        },
        .with { $0.math.offset = Int64(alt.utf16.count + 1)
          $0.math.length = Int64(formula.utf16.count)
        },
      ]
    }
    let (view, plan) = try richView(source: source, content: content)
    func descendants(_ root: UIView) -> [UIView] {
      [root] + root.subviews.flatMap(descendants)
    }
    let images = descendants(view).filter { $0.accessibilityLabel == alt }
    #expect(images.count == 2)
    #expect(Set(images.compactMap(\.accessibilityValue)) == ["Loading", "Unavailable"])
    for node in plan.nodes {
      guard case .math = node.kind else { continue }
      #expect(view.mathSource(at: CGPoint(x: node.frame.midX, y: node.frame.midY)) == formula)
    }
    #expect(view.mathSource(at: CGPoint(x: -1, y: -1)) == nil)
    view.prepareForReuse()
    #expect(view.mathSource(at: CGPoint(x: 10, y: 10)) == nil)
  }

  @Test("Disclosure accessibility activation uses the existing toggle callback")
  func disclosureActivation() throws {
    let content = BlockContent.with {
      $0.blocks = [.with {
        $0.disclosure.summary.length = 7
        $0.disclosure.initiallyOpen = false
        $0.disclosure.children = [.with { $0.paragraph.offset = 8
          $0.paragraph.length = 4
        }]
      }]
    }
    let (view, _) = try richView(source: "Details\nBody", content: content)
    var expanded: Bool?
    view.onDisclosureToggle = { _, value in expanded = value }
    let button = try #require(view.subviews.first { $0.accessibilityTraits.contains(.button) })
    #expect(button.accessibilityActivate())
    #expect(expanded == true)
    view.prepareForReuse()
  }

  private func richView(
    source: String,
    content: BlockContent
  ) throws -> (RichBlockContentViewV2, RichBlockLayoutPlanV2) {
    let attributed = NSAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 17)])
    let payload = try #require(BlockContentPayload(content))
    let plan = try #require(RichBlockLayoutPlannerV2.shared.plan(
      content: content, contentCacheSignature: payload.cacheSignature, contentByteCount: payload.byteCount,
      attributedText: attributed, availableWidth: 300, baseFontSize: 17, disclosureOverrides: [:]
    ))
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message.message
    message.text = source
    message.blockContentPayload = payload
    let view = RichBlockContentViewV2(frame: CGRect(origin: .zero, size: plan.size))
    view.update(
      plan: plan, content: content, attributedText: attributed, baseFontSize: 17,
      palette: RichBlockPaletteV2(
        primary: .label,
        secondary: .secondaryLabel,
        accent: .systemBlue,
        subtleFill: .secondarySystemFill,
        codeFill: .secondarySystemFill,
        separator: .separator,
        placeholder: .tertiaryLabel
      ),
      message: message, mathPreparationEnabled: false, deferLayout: false, transitionGeneration: 0
    )
    view.layoutIfNeeded()
    return (view, plan)
  }

  @Test("Collapsed links do not create targets in the hidden flat fallback")
  func collapsedLinkHit() throws {
    let source = "Details\nhttps://example.com\nx"
    let link = (source as NSString).range(of: "https://example.com")
    var full = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    full.message.globalId = 99_801
    full.message.messageId = 99_801
    full.message.text = source
    full.message.blockContentPayload = try #require(BlockContentPayload(.with {
      $0.blocks = [
        .with {
          $0.disclosure.summary = .with { $0.offset = 0
            $0.length = 7
          }
          $0.disclosure.initiallyOpen = false
          $0.disclosure.children = [.with {
            $0.paragraph.offset = Int64(link.location)
            $0.paragraph.length = Int64(link.length)
          }]
        },
        .with { $0.paragraph.offset = Int64(source.utf16.count - 1)
          $0.paragraph.length = 1
        },
      ]
    }))
    let view = UIMessageView2(
      fullMessage: full, spaceId: nil, displayMode: .normal,
      bubbleTailSide: .leading, maximumBubbleContentWidth: 297.5,
      theme: ThemeManager.shared.snapshot(variant: .light)
    )
    view.frame.size = view.sizeThatFits(CGSize(width: 350, height: CGFloat.greatestFiniteMagnitude))
    view.layoutIfNeeded()
    let flat = view.messageLabel
    #expect(flat.alpha == 0)
    #expect(flat.textStorage.length == 0)
    // A stale or externally populated fallback must still never steal hits
    // from the visible rich projection.
    flat.attributedText = try #require(view.attributedMessageText())
    #expect(flat.attributedText.attribute(.link, at: link.location, effectiveRange: nil) != nil)
    flat.layoutManager.ensureLayout(for: flat.textContainer)
    let glyphs = flat.layoutManager.glyphRange(forCharacterRange: link, actualCharacterRange: nil)
    var checked = 0
    flat.layoutManager.enumerateEnclosingRects(
      forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
      in: flat.textContainer
    ) { rect, _ in
      let point = CGPoint(x: rect.midX, y: rect.midY)
      guard flat.bounds.contains(point) else { return }
      let inMessage = flat.convert(point, to: view)
      #expect(view.linkURL(atPointInMessageView: inMessage) == nil)
      #expect(!view.hasInteractiveTextTarget(atPointInMessageView: inMessage))
      checked += 1
    }
    #expect(checked > 0)
    view.cancelPendingGeometryTransitions()
  }

  @Test("Link and mention hits retain UTF-16 positions after emoji", arguments: [false, true])
  func entityGeometry(rtl: Bool) throws {
    let source = rtl ? "سلام 👩🏽‍💻 پیوند و Mo" : "Hello 👩🏽‍💻 link and Mo"
    let linkRange = (source as NSString).range(of: rtl ? "پیوند" : "link")
    let mentionRange = (source as NSString).range(of: "Mo")
    let url = try #require(URL(string: "https://example.com"))
    let attributed = NSMutableAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 17)])
    attributed.addAttribute(.link, value: url, range: linkRange)
    attributed.addAttribute(.mentionUserId, value: Int64(7_001), range: mentionRange)
    let content = BlockContent.with {
      $0.blocks = [.with {
        $0.paragraph.offset = 0
        $0.paragraph.length = Int64(source.utf16.count)
        $0.paragraph.isRtl = rtl
      }]
    }
    let payload = try #require(BlockContentPayload(content))
    let plan = try #require(RichBlockLayoutPlannerV2.shared.plan(
      content: content, contentCacheSignature: payload.cacheSignature, contentByteCount: payload.byteCount,
      attributedText: attributed, availableWidth: 300, baseFontSize: 17, disclosureOverrides: [:]
    ))
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message.message
    message.text = source
    message.blockContentPayload = payload
    let view = RichBlockContentViewV2(frame: CGRect(origin: .zero, size: plan.size))
    view.update(
      plan: plan, content: content, attributedText: attributed, baseFontSize: 17,
      palette: RichBlockPaletteV2(
        primary: .label, secondary: .secondaryLabel, accent: .systemBlue,
        subtleFill: .secondarySystemFill, codeFill: .secondarySystemFill,
        separator: .separator, placeholder: .tertiaryLabel
      ),
      message: message, mathPreparationEnabled: false, deferLayout: false, transitionGeneration: 0
    )
    view.layoutIfNeeded()
    let text = try #require(view.primaryTextSurface)
    text.layoutManager.ensureLayout(for: text.textContainer)

    for range in [linkRange, mentionRange] {
      let start = try #require(text.position(from: text.beginningOfDocument, offset: range.location))
      let end = try #require(text.position(from: start, offset: range.length))
      let selection = try #require(text.textRange(from: start, to: end))
      // Native selection geometry accounts for Arabic shaping and bidi clusters;
      // a single glyph's ink bounds can overlap neighboring emoji or letters.
      let rect = try #require(text.selectionRects(for: selection).first { !$0.rect.isEmpty }).rect
      let point = text.convert(CGPoint(x: rect.midX, y: rect.midY), to: view)
      let hit = try #require(view.entityHit(at: point))
      #expect(
        NSLocationInRange(hit.characterIndex, range),
        "Expected \(range), hit \(hit.characterIndex), rect \(rect), bounds \(text.bounds), offset \(text.contentOffset)"
      )
      #expect(
        richTextHasInteractiveEntity(at: hit.characterIndex, in: hit.text),
        "Expected interactive entity at \(hit.characterIndex) in \(range)"
      )
    }
    let actions = view.subviews.flatMap { $0.accessibilityCustomActions ?? [] }
    #expect(actions.count == 2)
    view.prepareForReuse()
    #expect(view.primaryTextSurface == nil)
    #expect(view.entityHit(at: CGPoint(x: 10, y: 10)) == nil)
  }
}
