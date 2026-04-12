#if os(iOS)
import SwiftUI

struct AttachmentPickerRecentStrip: View {
  let items: [AttachmentPickerModel.RecentItem]
  let selectedItemIds: Set<String>
  let openCamera: () -> Void
  let openLibrary: () -> Void
  let toggleSelection: (String) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: AttachmentPickerTileMetrics.tileSpacing) {
        AttachmentPickerCameraTile(action: openCamera)
        AttachmentPickerPhotosTile(action: openLibrary)

        ForEach(items) { item in
          AttachmentPickerRecentTile(
            item: item,
            isSelected: selectedItemIds.contains(item.localIdentifier),
            onSelectToggle: {
              toggleSelection(item.localIdentifier)
            }
          )
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, AttachmentPickerTileMetrics.rowVerticalInset)
    }
    .scrollClipDisabled()
    .frame(height: AttachmentPickerTileMetrics.rowHeight)
  }
}
#endif
