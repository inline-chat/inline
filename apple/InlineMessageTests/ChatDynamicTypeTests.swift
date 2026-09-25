@testable import InlineIOS
import InlineKit
import Testing
import SwiftUI
import InlineUI
import UIKit

@Suite("Chat Dynamic Type", .serialized)
@MainActor
struct ChatDynamicTypeTests {
  @Test("Both message renderers rebuild cached text at the selected size", arguments: [false, true])
  func messageFonts(v2: Bool) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "Readable text with enough words to wrap into several lines at a larger size."
    message.message.entities = nil
    message.message.blockContentPayload = nil
    let theme = ThemeManager.shared.snapshot(variant: .light)
    let view: UIMessageView = v2
      ? UIMessageView2(fullMessage: message, spaceId: nil, displayMode: .normal, bubbleTailSide: .none,
                      maximumBubbleContentWidth: 280, theme: theme)
      : UIMessageView(fullMessage: message, spaceId: nil, maximumBubbleContentWidth: 280, theme: theme)

    func font(at category: UIContentSizeCategory) throws -> UIFont {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      let text = try #require(view.attributedMessageText())
      return try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    }

    let normal = try font(at: .large)
    let large = try font(at: .accessibilityExtraExtraExtraLarge)
    #expect(normal.pointSize == 17)
    #expect(large.pointSize > normal.pointSize)
    #expect(try font(at: .large).pointSize == normal.pointSize)
  }

  @Test("Unchanged messages are reconfigured after changing text size", arguments: [false, true])
  func unchangedCell(v2: Bool) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.text = "A message that is already on screen"
    message.message.blockContentPayload = nil
    let cell = MessageCollectionViewCell(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
    func configure() {
      cell.configure(
        with: message, firstInGroup: true, lastInGroup: true, spaceId: nil,
        collectionWidth: 320, theme: ThemeManager.shared.snapshot(variant: .light),
        messageViewImplementation: v2 ? .v2 : .legacy
      )
    }
    cell.traitOverrides.preferredContentSizeCategory = .large
    cell.updateTraitsIfNeeded()
    configure()
    let first = try #require(cell.messageView)
    configure()
    #expect(cell.messageView === first)
    cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    cell.updateTraitsIfNeeded()
    configure()
    #expect(cell.messageView !== first)
  }

  @Test("Status symbols grow with the timestamp in every delivery state", arguments: [MessageSendingStatus.sent, .sending, .failed])
  func statusSymbols(status: MessageSendingStatus) throws {
    var message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    message.message.out = true
    message.message.status = status
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let view = MessageTimeAndStatus(message)
    controller.view.addSubview(view)
    let symbol = try #require(view.subviews.compactMap { $0 as? UIImageView }.first)
    let label = try #require(view.subviews.compactMap { $0 as? UILabel }.first)
    var previousWidth: CGFloat = 0
    for category in [UIContentSizeCategory.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge] {
      view.traitOverrides.preferredContentSizeCategory = category
      view.updateTraitsIfNeeded()
      view.frame = CGRect(origin: .zero, size: view.intrinsicContentSize)
      view.layoutIfNeeded()
      #expect(symbol.bounds.width >= previousWidth)
      #expect(abs(symbol.bounds.width - label.font.pointSize) < 1)
      #expect(symbol.frame.maxX <= view.bounds.maxX + 1)
      #expect(symbol.frame.minY >= -1)
      #expect(symbol.frame.maxY <= view.bounds.maxY + 1)
      previousWidth = symbol.bounds.width
    }
    #expect(previousWidth > 11)
  }

  @Test("UIKit controls grow their symbol and touch container together")
  func uiKitControlSizing() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let button = ComposeVoiceButton(frame: .zero)
    button.isHidden = false
    controller.view.addSubview(button)
    NSLayoutConstraint.activate([
      button.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
      button.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: ComposeVoiceButton.size).scaledForContentSize(),
      button.heightAnchor.constraint(equalToConstant: ComposeVoiceButton.size).scaledForContentSize(),
    ])
    var originalSymbolSize: CGFloat = 0
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
      button.traitOverrides.preferredContentSizeCategory = category
      button.updateTraitsIfNeeded()
      window.layoutIfNeeded()
      let symbol = try #require(button.imageView)
      let expectedSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: ComposeVoiceButton.size, compatibleWith: button.traitCollection)
      #expect(abs(button.bounds.height - expectedSize) < 1)
      #expect(symbol.frame.maxY <= button.bounds.height + 1)
      #expect(symbol.frame.minY >= -1)
      if category == .large {
        originalSymbolSize = symbol.bounds.height
      } else {
        #expect(symbol.bounds.height > originalSymbolSize)
      }
    }
  }

  @Test("Custom icon chrome follows the Dynamic Type environment")
  func swiftUIIconSizing() throws {
    func size(at category: DynamicTypeSize) throws -> CGSize {
      let renderer = ImageRenderer(content:
        Image(systemName: "gearshape.fill")
          .scaledFont(size: 16)
          .scaledFrame(width: 25, height: 25)
          .environment(\.dynamicTypeSize, category)
      )
      return try #require(renderer.uiImage).size
    }
    let normal = try size(at: .large)
    let largest = try size(at: .accessibility5)
    #expect(normal.width == 25)
    #expect(largest.width > normal.width * 2)
    #expect(largest.width == largest.height)
  }

  @Test("Toolbar badges align with title capitals at small and accessibility sizes")
  func toolbarBadgeAlignment() throws {
    for (size, category) in [(DynamicTypeSize.xSmall, UIContentSizeCategory.extraSmall), (.large, .large), (.accessibility5, .accessibilityExtraExtraExtraLarge)] {
      let measurement = BadgeMeasurement()
      let renderer = ImageRenderer(content:
        BadgeMeasuringLayout(measurement: measurement) {
          Text("INLINE").font(.body.weight(.medium))
          ChatToolbarBadge { side in
            InlineTeamToolbarBadge(size: side)
          }
        }
        .environment(\.dynamicTypeSize, size)
      )
      _ = try #require(renderer.uiImage)
      let expectedFont = ChatTypography.font(17, weight: .medium, compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
      #expect(abs(measurement.badgeSide - expectedFont.pointSize) < 1)
      #expect(abs(measurement.badgeCenterAboveBaseline - expectedFont.capHeight / 2) < 1)
    }
  }

  @Test("Voice review controls wrap without clipping on narrow accessibility layouts")
  func voiceControlsWrap() throws {
    func render(width: CGFloat) throws -> (image: CGSize, hosted: CGSize) {
      let content = VoiceComposeControlsLayout {
        ForEach(["xmark", "play.fill", "arrow.up"], id: \.self) { symbol in
          Image(systemName: symbol)
            .scaledFont(size: 11, weight: .semibold, relativeTo: .caption)
            .scaledFrame(width: 30, height: 30, relativeTo: .caption)
        }
      }
      .frame(width: width)
      .environment(\.dynamicTypeSize, .accessibility5)
      let renderer = ImageRenderer(content: content)
      let size = try #require(renderer.uiImage).size
      let host = UIHostingController(rootView: content)
      host.safeAreaRegions = []
      let measured = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
      return (size, measured)
    }
    let wide = try render(width: 600)
    let narrow = try render(width: 180)
    // Rendering and UIKit hosting resolve fonts separately; both must wrap and stay bounded.
    for (wideSize, narrowSize) in [(wide.image, narrow.image), (wide.hosted, narrow.hosted)] {
      #expect(narrowSize.width == 180)
      #expect(narrowSize.height > wideSize.height * 1.5)
      #expect(narrowSize.height <= wideSize.height * 3 + 16)
    }
  }

  @Test("Timestamp and reply measurements grow along with their fonts")
  func accessoryMeasurements() throws {
    let message = try #require(MessageView2PlaygroundFixtures.scenarios.first).message
    let normal = UITraitCollection(preferredContentSizeCategory: .large)
    let large = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
    #expect(MessageTimeAndStatus.measuredWidth(for: message, compatibleWith: large)
      > MessageTimeAndStatus.measuredWidth(for: message, compatibleWith: normal))
    for style in [EmbedMessageView.Style.replyBubble, .compose] {
      #expect(EmbedMessageView.height(for: style, compatibleWith: large)
        > EmbedMessageView.height(for: style, compatibleWith: normal))
    }
  }

  @Test("Changing composer size preserves text, selection, links, and font traits")
  func composerPreservesDraft() throws {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIViewController()
    window.rootViewController = controller
    window.isHidden = false
    defer { window.isHidden = true }
    let compose = ComposeView(frame: CGRect(x: 0, y: 0, width: 320, height: 60))
    controller.view.addSubview(compose)
    let view = compose.textView
    view.traitOverrides.preferredContentSizeCategory = .large
    view.updateTraitsIfNeeded()
    let link = URL(string: "https://example.com")!
    view.attributedText = NSAttributedString(string: "Draft", attributes: [
      .font: UIFont.boldSystemFont(ofSize: 17), .link: link,
    ])
    view.selectedRange = NSRange(location: 2, length: 0)
    view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
    view.updateTraitsIfNeeded()
    view.layoutIfNeeded()
    let font = try #require(view.textStorage.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(view.text == "Draft")
    #expect(view.selectedRange == NSRange(location: 2, length: 0))
    #expect(font.pointSize > 17)
    #expect(font.fontDescriptor.symbolicTraits.contains(.traitBold))
    #expect(view.textStorage.attribute(.link, at: 0, effectiveRange: nil) as? URL == link)
    #expect((view.typingAttributes[.font] as? UIFont)?.pointSize == font.pointSize)
    view.text = ""
    compose.resetHeight(animated: false)
    #expect(compose.composeHeightConstraint.constant >= ceil(font.lineHeight)
      + view.textContainerInset.top + view.textContainerInset.bottom)
  }
}

private final class BadgeMeasurement {
  var badgeSide: CGFloat = 0
  var badgeCenterAboveBaseline: CGFloat = 0
}

private struct BadgeMeasuringLayout: Layout {
  let measurement: BadgeMeasurement

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let title = subviews[0].dimensions(in: .unspecified)
    let badge = subviews[1].dimensions(in: .unspecified)
    measurement.badgeSide = badge.height
    measurement.badgeCenterAboveBaseline = badge[.firstTextBaseline] - badge.height / 2
    let baseline = max(title[.firstTextBaseline], badge[.firstTextBaseline])
    return CGSize(width: title.width + 4 + badge.width,
                  height: baseline + max(title.height - title[.firstTextBaseline], badge.height - badge[.firstTextBaseline]))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let title = subviews[0].dimensions(in: .unspecified)
    let badge = subviews[1].dimensions(in: .unspecified)
    let baseline = max(title[.firstTextBaseline], badge[.firstTextBaseline])
    subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + baseline - title[.firstTextBaseline]), proposal: .unspecified)
    subviews[1].place(at: CGPoint(x: bounds.minX + title.width + 4, y: bounds.minY + baseline - badge[.firstTextBaseline]), proposal: .unspecified)
  }
}
