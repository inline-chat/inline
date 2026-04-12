#if os(iOS)
import SwiftUI

public struct AttachmentPickerCameraTile: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    AttachmentPickerActionTile(
      title: "Camera",
      systemImage: "camera",
      action: action
    )
    .accessibilityLabel("Camera")
  }
}

public struct AttachmentPickerPhotosTile: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    AttachmentPickerActionTile(
      title: "Photos",
      systemImage: "photo.on.rectangle.angled",
      action: action
    )
    .accessibilityLabel("Photos")
  }
}

private struct AttachmentPickerActionTile: View {
  private let title: String
  private let systemImage: String
  private let action: () -> Void

  init(title: String, systemImage: String, action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: systemImage)
          .foregroundStyle(.primary)

        Text(title)
          .foregroundStyle(.primary)
      }
      .frame(
        width: AttachmentPickerTileMetrics.thumbnailSide,
        height: AttachmentPickerTileMetrics.thumbnailSide
      )
      .background(
        RoundedRectangle(cornerRadius: AttachmentPickerTileMetrics.cornerRadius, style: .continuous)
          .fill(.quaternary.opacity(0.8))
      )
      .contentShape(.rect(cornerRadius: AttachmentPickerTileMetrics.cornerRadius))
    }
    .buttonStyle(.plain)
  }
}
#endif
