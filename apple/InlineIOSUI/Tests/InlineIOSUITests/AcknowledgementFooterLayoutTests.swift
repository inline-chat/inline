import CoreGraphics
import InlineIOSUI
import Testing

@Suite("Acknowledgement footer geometry")
struct AcknowledgementFooterLayoutTests {
  private let text = MessageLayoutNodeIDV2("body")
  private let metadata = MessageLayoutNodeIDV2("metadata")
  private let reactions = MessageLayoutNodeIDV2("reactions")
  private let acknowledgement = MessageLayoutNodeIDV2("acknowledgement")

  @Test(arguments: [false, true])
  func acknowledgementForcesPhysicalRightFooter(rtl: Bool) throws {
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 240,
      alignment: .leading,
      contentInsets: .init(top: 8, leading: 0, bottom: 8, trailing: 0),
      flowNodes: [
        .init(
          id: text,
          size: CGSize(width: 90, height: 20),
          insets: .init(top: 0, leading: 12, bottom: 0, trailing: 12)
        ),
      ],
      footer: .init(
        textNodeID: text,
        metadataNodeID: metadata,
        metadataSize: CGSize(width: 42, height: 14),
        acknowledgementNodeID: acknowledgement,
        acknowledgementSize: CGSize(width: 28, height: 16),
        isTextSingleLine: true,
        isRTL: rtl,
        horizontalSpacing: 5,
        verticalSpacing: 4
      )
    )))

    let metadataFrame = try #require(plan.nodeFrames[metadata])
    let acknowledgementFrame = try #require(plan.nodeFrames[acknowledgement])
    #expect(plan.footerPlacement == .metadataAndAcknowledgementFooter)
    #expect(metadataFrame.maxX + 5 == acknowledgementFrame.minX)
    #expect(acknowledgementFrame.maxX == plan.bubbleFrame.maxX - 12)
    #expect(metadataFrame.maxY == acknowledgementFrame.maxY)
  }

  @Test(arguments: [false, true])
  func reactionsTimeAndAcknowledgementShareOneFooter(rtl: Bool) throws {
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 360,
      maximumBubbleWidth: 280,
      alignment: .trailing,
      contentInsets: .init(top: 8, leading: 0, bottom: 8, trailing: 0),
      flowNodes: [
        .init(
          id: text,
          size: CGSize(width: 180, height: 40),
          insets: .init(top: 0, leading: 12, bottom: 0, trailing: 12)
        ),
      ],
      footer: .init(
        textNodeID: text,
        metadataNodeID: metadata,
        metadataSize: CGSize(width: 42, height: 14),
        reactionsNodeID: reactions,
        reactionsSize: CGSize(width: 74, height: 24),
        acknowledgementNodeID: acknowledgement,
        acknowledgementSize: CGSize(width: 42, height: 16),
        isTextSingleLine: false,
        isRTL: rtl,
        horizontalSpacing: 5,
        verticalSpacing: 4
      )
    )))

    let reactionsFrame = try #require(plan.nodeFrames[reactions])
    let metadataFrame = try #require(plan.nodeFrames[metadata])
    let acknowledgementFrame = try #require(plan.nodeFrames[acknowledgement])
    #expect(plan.footerPlacement == .reactionsMetadataAndAcknowledgementFooter)
    #expect(reactionsFrame.maxX < metadataFrame.minX)
    #expect(metadataFrame.maxX + 5 == acknowledgementFrame.minX)
    #expect(reactionsFrame.maxY == acknowledgementFrame.maxY)
    #expect(metadataFrame.maxY == acknowledgementFrame.maxY)
    #expect(acknowledgementFrame.maxX == plan.bubbleFrame.maxX - 12)
  }

  @Test func mediaReactionsTimeAndAcknowledgementShareExternalRow() throws {
    let media = MessageLayoutNodeIDV2("media")
    let accessoryRow = MessageLayoutNodeIDV2("accessory-row")
    let plan = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: 320,
      maximumBubbleWidth: 220,
      alignment: .leading,
      contentInsets: .zero,
      flowNodes: [
        .init(
          id: media,
          size: CGSize(width: 220, height: 130),
          widthBehavior: .fill,
          forcesMaximumWidth: true
        ),
      ],
      overlayNodes: [
        .init(
          id: reactions,
          targetID: accessoryRow,
          size: CGSize(width: 74, height: 24),
          anchor: .bottomLeading
        ),
        .init(
          id: metadata,
          targetID: accessoryRow,
          size: CGSize(width: 42, height: 14),
          anchor: .bottomTrailing,
          insets: .init(top: 0, leading: 0, bottom: 0, trailing: 33)
        ),
        .init(
          id: acknowledgement,
          targetID: accessoryRow,
          size: CGSize(width: 28, height: 16),
          anchor: .bottomTrailing
        ),
      ],
      belowBubbleNodes: [
        .init(
          id: accessoryRow,
          size: CGSize(width: 0, height: 24),
          spacingBefore: 3,
          widthBehavior: .fill
        ),
      ]
    )))

    let accessoryFrame = try #require(plan.nodeFrames[accessoryRow])
    let reactionsFrame = try #require(plan.nodeFrames[reactions])
    let metadataFrame = try #require(plan.nodeFrames[metadata])
    let acknowledgementFrame = try #require(plan.nodeFrames[acknowledgement])
    #expect(reactionsFrame.minX == accessoryFrame.minX)
    #expect(metadataFrame.maxX + 5 == acknowledgementFrame.minX)
    #expect(acknowledgementFrame.maxX == accessoryFrame.maxX)
    #expect(reactionsFrame.maxY == acknowledgementFrame.maxY)
    #expect(metadataFrame.maxY == acknowledgementFrame.maxY)
  }
}
