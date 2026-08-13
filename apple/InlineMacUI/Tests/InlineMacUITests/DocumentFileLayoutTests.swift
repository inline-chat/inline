import CoreGraphics
import Testing
@testable import InlineMacUI

@Suite("Document file layout")
struct DocumentFileLayoutTests {
  @Test("preferred width follows the wider text row")
  func preferredWidthUsesContent() {
    let metadataLed = DocumentFileLayoutPlan.preferredWidth(
      hasThumbnail: true,
      minimumWidth: 200,
      fileNameWidth: 70,
      metadataWidth: 144
    )
    let filenameLed = DocumentFileLayoutPlan.preferredWidth(
      hasThumbnail: true,
      minimumWidth: 200,
      fileNameWidth: 320,
      metadataWidth: 144
    )

    #expect(metadataLed == 224)
    #expect(filenameLed == 400)
  }

  @Test("action follows file size instead of trailing edge")
  func actionIsMetadataAdjacent() {
    let plan = DocumentFileLayoutPlan.make(
      media: .init(hasThumbnail: true, height: 70, width: 360),
      metadata: .init(fileSizeWidth: 52, actionWidth: 90, allowsAction: true, showsClose: false)
    )

    #expect(plan.showsAction)
    #expect(plan.actionFrame.minX == plan.fileSizeFrame.maxX + DocumentFileLayoutPlan.metadataSpacing)
    #expect(plan.actionFrame.maxX < plan.size.width)
  }

  @Test("preferred width always fits its reserved action row")
  func preferredWidthFitsAction() {
    for hasThumbnail in [false, true] {
      for metrics in [
        (fileSize: CGFloat(31), action: CGFloat(72)),
        (fileSize: CGFloat(58.5), action: CGFloat(100)),
      ] {
        let metadataWidth = metrics.fileSize + DocumentFileLayoutPlan.metadataSpacing + metrics.action
        let width = DocumentFileLayoutPlan.preferredWidth(
          hasThumbnail: hasThumbnail,
          minimumWidth: 200,
          fileNameWidth: 80,
          metadataWidth: metadataWidth
        )
        let height = hasThumbnail ? DocumentFileLayoutPlan.thumbnailSize : CGFloat(40)
        let plan = DocumentFileLayoutPlan.make(
          media: .init(hasThumbnail: hasThumbnail, height: height, width: width),
          metadata: .init(
            fileSizeWidth: metrics.fileSize,
            actionWidth: metrics.action,
            allowsAction: true,
            showsClose: false
          )
        )

        #expect(plan.showsAction)
        #expect(plan.actionFrame.maxX <= width)
      }
    }
  }

  @Test("narrow rows preserve metadata and hide the action")
  func narrowRowsHideAction() {
    let plan = DocumentFileLayoutPlan.make(
      media: .init(hasThumbnail: true, height: 70, width: 170),
      metadata: .init(fileSizeWidth: 52, actionWidth: 90, allowsAction: true, showsClose: false)
    )

    #expect(!plan.showsAction)
    #expect(plan.actionFrame.width == 0)
    #expect(plan.fileSizeFrame.width == 52)
    #expect(plan.mediaFrame.size == CGSize(width: 70, height: 70))
  }
}
