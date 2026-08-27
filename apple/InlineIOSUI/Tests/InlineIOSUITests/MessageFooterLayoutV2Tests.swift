import CoreGraphics
import Testing

@testable import InlineIOSUI

@Suite("Message View 2 footer layout")
struct MessageFooterLayoutV2Tests {
  @Test("one-line text keeps metadata inline when it fits")
  func metadataFitsInline() throws {
    let layout = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 160, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: nil,
      isTextSingleLine: true,
      maximumWidth: 280,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))

    #expect(layout.placement == .inlineMetadata)
    #expect(layout.size == CGSize(width: 206, height: 22))
    #expect(layout.metadataFrame == CGRect(x: 166, y: 8, width: 40, height: 14))
  }

  @Test("adding a compact reaction footer moves time below and narrows the bubble")
  func reactionFooterNarrowsBubble() throws {
    let before = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 160, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: nil,
      isTextSingleLine: true,
      maximumWidth: 280,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))
    let after = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 160, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: CGSize(width: 50, height: 24),
      isTextSingleLine: true,
      maximumWidth: 280,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))

    #expect(before.size.width == 206)
    #expect(after.placement == .reactionsAndMetadataFooter)
    #expect(after.size == CGSize(width: 160, height: 50))
    #expect(after.reactionsFrame == CGRect(x: 0, y: 26, width: 50, height: 24))
    #expect(after.metadataFrame == CGRect(x: 120, y: 36, width: 40, height: 14))
  }

  @Test("an overflowing reaction footer stacks metadata deterministically")
  func overflowingFooterStacks() throws {
    let layout = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 140, height: 22),
      metadataSize: CGSize(width: 44, height: 14),
      reactionsSize: CGSize(width: 180, height: 24),
      isTextSingleLine: true,
      maximumWidth: 200,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))

    #expect(layout.placement == .stackedFooter)
    #expect(layout.size == CGSize(width: 180, height: 68))
    #expect(layout.reactionsFrame == CGRect(x: 0, y: 26, width: 180, height: 24))
    #expect(layout.metadataFrame == CGRect(x: 136, y: 54, width: 44, height: 14))
  }

  @Test("invalid measurements are rejected")
  func invalidMeasurementsAreRejected() {
    #expect(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: CGFloat.infinity, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: nil,
      isTextSingleLine: true,
      maximumWidth: 280,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ) == nil)
  }

  @Test("RTL footer mirrors text, reaction, and metadata placement")
  func rtlFooterMirrorsPlacement() throws {
    let inline = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 100, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: nil,
      isTextSingleLine: true,
      isRTL: true,
      maximumWidth: 200,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))
    #expect(inline.textFrame.minX == 46)
    #expect(inline.metadataFrame.minX == 0)

    let reacted = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 140, height: 22),
      metadataSize: CGSize(width: 40, height: 14),
      reactionsSize: CGSize(width: 52, height: 24),
      isTextSingleLine: true,
      isRTL: true,
      maximumWidth: 200,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))
    #expect(reacted.metadataFrame.minX == 0)
    #expect(reacted.reactionsFrame?.maxX == reacted.size.width)
  }

  @Test("rich text can place metadata on its final LTR line")
  func richTrailingLineFooter() throws {
    let layout = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 180, height: 64),
      metadataSize: CGSize(width: 42, height: 14),
      reactionsSize: nil,
      isTextSingleLine: false,
      trailingTextLine: .init(usedWidth: 92, height: 20, isRTL: false),
      maximumWidth: 220,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))

    #expect(layout.placement == .trailingTextLineMetadata)
    #expect(layout.size == CGSize(width: 180, height: 64))
    #expect(layout.metadataFrame == CGRect(x: 98, y: 50, width: 42, height: 14))
  }

  @Test("rich RTL trailing lines keep metadata below")
  func richRTLTailingLineDoesNotShareMetadata() throws {
    let layout = try #require(MessageFooterLayoutPlannerV2.layout(
      textSize: CGSize(width: 180, height: 64),
      metadataSize: CGSize(width: 42, height: 14),
      reactionsSize: nil,
      isTextSingleLine: false,
      trailingTextLine: .init(usedWidth: 92, height: 20, isRTL: true),
      maximumWidth: 220,
      horizontalSpacing: 6,
      verticalSpacing: 4
    ))

    #expect(layout.placement == .metadataBelow)
  }
}
