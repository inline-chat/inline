import CoreGraphics
import InlineIOSUI
import Testing

@Suite("Message bubble layout V2")
struct MessageBubbleLayoutV2Tests {
  private let text = MessageLayoutNodeIDV2("text")
  private let metadata = MessageLayoutNodeIDV2("metadata")
  private let reactions = MessageLayoutNodeIDV2("reactions")

  @Test("outgoing one-line text and metadata remain in one row")
  func outgoingInlineFooter() throws {
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 240,
      alignment: .trailing,
      contentInsets: .init(top: 8, leading: 10, bottom: 8, trailing: 10),
      flowNodes: [.init(id: text, size: CGSize(width: 82, height: 20))],
      footer: .init(
        textNodeID: text,
        metadataNodeID: metadata,
        metadataSize: CGSize(width: 42, height: 14),
        isTextSingleLine: true,
        horizontalSpacing: 5,
        verticalSpacing: 4
      )
    )))

    #expect(plan.footerPlacement == .inlineMetadata)
    #expect(plan.bubbleFrame.maxX == 320)
    #expect(plan.nodeFrames[metadata]?.minY == 14)
    #expect(plan.size.height == 36)
  }

  @Test("adding a reaction creates one compact synchronized footer geometry")
  func reactionFooter() throws {
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 160,
      alignment: .trailing,
      tailSide: .trailing,
      tailWidth: 5,
      contentInsets: .init(top: 8, leading: 10, bottom: 8, trailing: 10),
      flowNodes: [.init(id: text, size: CGSize(width: 90, height: 20))],
      footer: .init(
        textNodeID: text,
        metadataNodeID: metadata,
        metadataSize: CGSize(width: 42, height: 14),
        reactionsNodeID: reactions,
        reactionsSize: CGSize(width: 58, height: 24),
        isTextSingleLine: true,
        horizontalSpacing: 6,
        verticalSpacing: 4
      )
    )))

    #expect(plan.footerPlacement == .reactionsAndMetadataFooter)
    #expect(plan.bubbleFrame.maxX == 320)
    #expect(plan.bubbleFrame.width == 131)
    #expect(plan.nodeFrames[reactions]?.minY == 32)
    #expect(plan.nodeFrames[metadata]?.maxY == plan.nodeFrames[reactions]?.maxY)
  }

  @Test("filled media fixes the bubble width and below-bubble nodes stay aligned")
  func filledMediaAndExternalFooter() throws {
    let media = MessageLayoutNodeIDV2("media")
    let externalReactions = MessageLayoutNodeIDV2("external-reactions")
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 300,
      maximumBubbleWidth: 210,
      alignment: .leading,
      contentInsets: .zero,
      flowNodes: [
        .init(
          id: media,
          size: CGSize(width: 210, height: 150),
          widthBehavior: .fill,
          forcesMaximumWidth: true
        ),
      ],
      belowBubbleNodes: [
        .init(id: externalReactions, size: CGSize(width: 84, height: 26), spacingBefore: 4),
      ]
    )))

    #expect(plan.bubbleFrame.width == 210)
    #expect(plan.nodeFrames[media] == CGRect(x: 0, y: 0, width: 210, height: 150))
    #expect(plan.nodeFrames[externalReactions] == CGRect(x: 0, y: 154, width: 84, height: 26))
    #expect(plan.size.height == 180)
  }

  @Test("duplicate retained node identities are rejected")
  func duplicateIdentityRejected() {
    let duplicate = MessageLayoutNodeIDV2("duplicate")
    let plan = MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 300,
      maximumBubbleWidth: 200,
      alignment: .leading,
      contentInsets: .zero,
      flowNodes: [
        .init(id: duplicate, size: CGSize(width: 40, height: 20)),
        .init(id: duplicate, size: CGSize(width: 50, height: 20)),
      ]
    ))

    #expect(plan == nil)
  }

  @Test("floating metadata is positioned from the measured media node")
  func mediaOverlay() throws {
    let media = MessageLayoutNodeIDV2("media")
    let floatingMetadata = MessageLayoutNodeIDV2("floating-metadata")
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 300,
      maximumBubbleWidth: 220,
      alignment: .leading,
      contentInsets: .zero,
      flowNodes: [
        .init(
          id: media,
          size: CGSize(width: 220, height: 150),
          widthBehavior: .fill,
          forcesMaximumWidth: true
        ),
      ],
      overlayNodes: [
        .init(
          id: floatingMetadata,
          targetID: media,
          size: CGSize(width: 48, height: 20),
          anchor: .bottomTrailing,
          insets: .init(top: 0, leading: 0, bottom: 10, trailing: 12)
        ),
      ]
    )))

    #expect(plan.nodeFrames[floatingMetadata] == CGRect(x: 160, y: 120, width: 48, height: 20))
    #expect(plan.size.height == 150)
  }

  @Test("a fill node expands only to the width chosen by natural content")
  func fillDoesNotForceMaximumWidth() throws {
    let reply = MessageLayoutNodeIDV2("reply")
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 260,
      alignment: .leading,
      contentInsets: .zero,
      flowNodes: [
        .init(id: reply, size: CGSize(width: 180, height: 44), widthBehavior: .fill),
        .init(id: text, size: CGSize(width: 210, height: 20)),
      ]
    )))

    #expect(plan.bubbleFrame.width == 210)
    #expect(plan.nodeFrames[reply]?.width == 210)
  }

  @Test("below-bubble rows use the tail-excluding content span")
  func tailAwareBelowBubbleRows() throws {
    let actions = MessageLayoutNodeIDV2("actions")
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 225,
      minimumBubbleWidth: 225,
      alignment: .leading,
      tailSide: .leading,
      tailWidth: 5,
      contentInsets: .zero,
      flowNodes: [.init(id: text, size: CGSize(width: 160, height: 20))],
      belowBubbleNodes: [
        .init(id: actions, size: CGSize(width: 220, height: 32), widthBehavior: .fill),
      ]
    )))

    #expect(plan.bubbleContentFrame.minX == 5)
    #expect(plan.nodeFrames[actions] == CGRect(x: 5, y: 20, width: 220, height: 32))
  }
}
