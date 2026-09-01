import CoreGraphics
import InlineIOSUI
import Testing

@Suite("Acknowledgement footer geometry")
struct AcknowledgementFooterLayoutTests {
  @Test(arguments: [false, true], [CGSize(width: 28, height: 28), CGSize(width: 90, height: 20), CGSize(width: 180, height: 80), CGSize(width: 220, height: 160)])
  func footerUsesActualContentEdgeWithoutReflow(rtl: Bool, body: CGSize) throws {
    let text = MessageLayoutNodeIDV2("body")
    let ack = MessageLayoutNodeIDV2("acknowledgement")
    let input = MessageBubbleLayoutInputV2(
      containerWidth: 600, maximumBubbleWidth: 420,
      alignment: .leading,
      contentInsets: .init(top: 8, leading: 12, bottom: 8, trailing: 12),
      flowNodes: [.init(id: text, size: body)]
    )
    let before = try #require(MessageBubbleLayoutPlannerV2.layout(input))
    let after = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: input.containerWidth, maximumBubbleWidth: input.maximumBubbleWidth,
      alignment: input.alignment, contentInsets: input.contentInsets, flowNodes: input.flowNodes,
      belowBubbleNodes: [.init(id: ack, size: CGSize(width: 78, height: 16), spacingBefore: 4,
                              horizontalAlignment: rtl ? .leading : .trailing)]
    )))
    let frame = try #require(after.nodeFrames[ack])
    #expect(before.bubbleFrame == after.bubbleFrame)
    #expect(before.nodeFrames[text] == after.nodeFrames[text])
    #expect(after.size.height == before.size.height + 20)
    #expect(frame.height == 16)
    #expect(frame.width <= body.width)
    #expect(rtl ? frame.minX == after.bubbleContentFrame.minX : frame.maxX == after.bubbleContentFrame.maxX)
    #expect(frame.maxX < input.maximumBubbleWidth)
  }

  @Test(arguments: [false, true], [CGFloat(40), CGFloat(48)])
  func largeActorCountDoesNotWidenTinyMessage(rtl: Bool, minimumWidth: CGFloat) throws {
    let text = MessageLayoutNodeIDV2("body")
    let ack = MessageLayoutNodeIDV2("acknowledgement")
    let input = MessageBubbleLayoutInputV2(
      containerWidth: 600, maximumBubbleWidth: 420, alignment: .leading,
      contentInsets: .init(top: 8, leading: 12, bottom: 8, trailing: 12),
      flowNodes: [.init(id: text, size: CGSize(width: 20, height: 20))]
    )
    let before = try #require(MessageBubbleLayoutPlannerV2.layout(input))
    let after = try #require(MessageBubbleLayoutPlannerV2.layout(.init(
      containerWidth: input.containerWidth, maximumBubbleWidth: input.maximumBubbleWidth,
      alignment: input.alignment, contentInsets: input.contentInsets, flowNodes: input.flowNodes,
      belowBubbleNodes: [.init(
        id: ack, size: CGSize(width: 90, height: 16), spacingBefore: 4,
        horizontalAlignment: rtl ? .leading : .trailing, minimumWidth: minimumWidth
      )]
    )))
    let frame = try #require(after.nodeFrames[ack])
    #expect(before.bubbleFrame == after.bubbleFrame)
    #expect(before.nodeFrames[text] == after.nodeFrames[text])
    #expect(frame.width == minimumWidth)
    #expect(after.size.height == before.size.height + 20)
    #expect(rtl ? frame.minX == after.bubbleContentFrame.minX : frame.maxX == after.bubbleContentFrame.maxX)
  }

}
