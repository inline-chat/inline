@testable import InlineIOS
import InlineKit
import InlineProtocol
import InlineTheme
import Testing
import UIKit

@Suite("Agent activity standard bubble colors", .serialized)
@MainActor
struct QuietAgentActivityColorsTests {
  private let source = "Worked\nRead guide and code\nFooter"

  @Test("Both renderers retain standard bubbles and link colors for agent activity", arguments: [false, true])
  func foregrounds(dark: Bool) throws {
    let theme = IOSThemeSnapshot.resolve(preset: .system, variant: dark ? .dark : .light)
    for outgoing in [false, true] {
      for forwarded in [false, true] {
        // Reuse the exact identity/text to exercise both attributed-text caches
        // when only the disclosure marker changes. Presentation must stay ordinary.
        for quiet in [true, false, true] {
          let full = try message(outgoing: outgoing, forwarded: forwarded, quiet: quiet)
          let legacy = UIMessageView(
            fullMessage: full, spaceId: nil, maximumBubbleContentWidth: 300,
            theme: theme, buildHierarchy: false
          )
          let modern = makeV2(full, theme: theme, mode: .fixtureMeasurement)
          let bubble = outgoing ? theme.outgoingBubble.uiColor : theme.incomingBubble.uiColor
          let primary = outgoing ? UIColor.white : theme.incomingText.uiColor
          let accent = outgoing ? UIColor.white : theme.primary.uiColor
          for view: UIMessageView in [legacy, modern] {
            view.setupAppearance()
            #expect(view.outgoing == outgoing)
            #expect(view.bubbleColor.isEqual(bubble))
            #expect(view.textColor.isEqual(primary))
            let attributed = try #require(view.attributedMessageText())
            #expect(color(attributed, at: 0)?.isEqual(primary) == true)
            let link = (source as NSString).range(of: "guide")
            #expect(color(attributed, at: link.location)?.isEqual(accent) == true)
            #expect(attributed.attribute(.link, at: link.location, effectiveRange: nil) != nil)
            let code = (source as NSString).range(of: "code")
            #expect(color(attributed, at: code.location)?.isEqual(primary) == true)
            if outgoing {
              #expect(view.metadataView.textColor.isEqual(UIColor.white.withAlphaComponent(0.7)))
              #expect(view.metadataView.imageColor.isEqual(UIColor.white.withAlphaComponent(0.7)))
            }
          }
        }
      }
    }
  }

  #if DEBUG || DEBUG_BUILD
  @Test("Forwarded activity uses outgoing bubble colors without a decorative icon", arguments: [false, true])
  func renderedDisclosure(dark: Bool) throws {
    let theme = IOSThemeSnapshot.resolve(preset: .system, variant: dark ? .dark : .light)
    let full = try message(outgoing: true, forwarded: true, quiet: true)
    let measurement = makeV2(full, theme: theme, mode: .fixtureMeasurement)
    let prepared = try #require(measurement.prepareListLayout(width: 350))
    let display = makeV2(full, theme: theme, mode: .fixtureDisplay)
    display.frame.size = prepared.bubble.size
    #expect(display.installListLayout(prepared, message: full, animated: false))
    let nodes = descendants(display)
    let disclosure = try #require(nodes.first {
      $0.accessibilityLabel == "Worked" && $0.accessibilityTraits.contains(.button)
    })
    let title = try #require(descendants(disclosure).compactMap { $0 as? UITextView }.first)
    #expect(display.bubbleColor.isEqual(theme.outgoingBubble.uiColor))
    #expect(color(title.attributedText, at: 0)?.isEqual(UIColor.white.withAlphaComponent(0.7)) == true)
    let icons = descendants(disclosure).compactMap { $0 as? UIImageView }.filter { !$0.isHidden }
    #expect(icons.count == 1) // The existing expand/collapse chevron only.
    #expect(icons.allSatisfy { $0.tintColor.isEqual(UIColor.white.withAlphaComponent(0.7)) })
    let body = try #require(nodes.compactMap { $0 as? UITextView }.first { $0.text == "Read guide and code" })
    #expect(color(body.attributedText, at: 0)?.isEqual(UIColor.white) == true)
    #expect(color(body.attributedText, at: 5)?.isEqual(UIColor.white) == true)
    display.cancelPendingGeometryTransitions()
  }
  #endif

  @Test("Changing the activity marker preserves the bubble and metadata colors")
  func markerPreservesBubbleColors() throws {
    let theme = IOSThemeSnapshot.resolve(preset: .system, variant: .light)
    let full = try message(outgoing: true, forwarded: true, quiet: true)
    let view = makeV2(full, theme: theme, mode: .fixtureDisplay)
    #expect(view.bubbleColor.isEqual(theme.outgoingBubble.uiColor))
    #expect(view.metadataView.textColor.isEqual(UIColor.white.withAlphaComponent(0.7)))
    let ordinary = try message(outgoing: true, forwarded: true, quiet: false)
    view.applySnapshot(ordinary)
    #expect(view.bubbleColor.isEqual(theme.outgoingBubble.uiColor))
    #expect(view.metadataView.textColor.isEqual(UIColor.white.withAlphaComponent(0.7)))
    #expect(view.textColor.isEqual(UIColor.white))
    view.applySnapshot(full)
    #expect(view.bubbleColor.isEqual(theme.outgoingBubble.uiColor))
    #expect(view.metadataView.textColor.isEqual(UIColor.white.withAlphaComponent(0.7)))
    view.cancelPendingGeometryTransitions()
  }

  private func message(outgoing: Bool, forwarded: Bool, quiet: Bool) throws -> FullMessage {
    func range(_ text: String) -> BlockText {
      let range = (source as NSString).range(of: text)
      return .with { $0.offset = Int64(range.location); $0.length = Int64(range.length) }
    }
    let content = BlockContent.with {
      $0.blocks = [.with {
        $0.disclosure.summary = range("Worked")
        $0.disclosure.activityKind = quiet ? .agent : .tool
        $0.disclosure.initiallyOpen = true
        $0.disclosure.children = [
          .with { $0.paragraph = range("Read guide and code") },
          .with { $0.footer = range("Footer") },
        ]
      }]
    }
    let link = (source as NSString).range(of: "guide")
    let code = (source as NSString).range(of: "code")
    var message = InlineKit.Message(
      messageId: -90_011, fromId: 2, date: Date(timeIntervalSince1970: 1_700_000_000),
      text: source, peerUserId: nil, peerThreadId: -90_010, chatId: -90_010,
      out: outgoing, status: .sent, forwardFromUserId: forwarded ? 3 : nil,
      blockContentPayload: try #require(BlockContentPayload(content)),
      entities: .with { $0.entities = [
        .with { $0.type = .textURL; $0.offset = Int64(link.location); $0.length = Int64(link.length)
          $0.textURL.url = "https://example.invalid/guide"
        },
        .with { $0.type = .code; $0.offset = Int64(code.location); $0.length = Int64(code.length) },
      ] }
    )
    message.globalId = -90_011
    return FullMessage(senderInfo: nil, message: message, reactions: [], repliedToMessage: nil, attachments: [])
  }

  private func makeV2(
    _ full: FullMessage, theme: IOSThemeSnapshot, mode: UIMessageView2.RenderingMode
  ) -> UIMessageView2 {
    UIMessageView2(
      fullMessage: full, spaceId: nil, displayMode: .normal,
      bubbleTailSide: full.message.out == true ? .trailing : .leading,
      maximumBubbleContentWidth: 300, theme: theme, renderingMode: mode
    )
  }

  private func color(_ text: NSAttributedString, at offset: Int) -> UIColor? {
    text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? UIColor
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
