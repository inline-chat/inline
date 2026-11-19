import InlineKit
import QuickLookThumbnailing
import SwiftUI

/// A Quick Look thumbnail of a downloaded file, with the category's symbol until it loads.
public struct StorageThumbnail: View {
  let item: StorageItem
  let size: CGFloat

  @Environment(\.displayScale) private var displayScale
  @State private var image: CGImage?

  public init(item: StorageItem, size: CGFloat = 32) {
    self.item = item
    self.size = size
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        .fill(StorageCategoryStyle.color(item.category).opacity(0.16))
      if let image {
        Image(decorative: image, scale: displayScale)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
          .transition(.opacity)
      } else {
        Image(systemName: item.category.systemImage)
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(StorageCategoryStyle.color(item.category))
      }
    }
    .frame(width: size, height: size)
    .task(id: item.id) { await load() }
  }

  private func load() async {
    guard item.category != .voice else { return }
    let request = QLThumbnailGenerator.Request(
      fileAt: item.url,
      size: CGSize(width: size, height: size),
      scale: displayScale,
      representationTypes: .thumbnail
    )
    guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
          !Task.isCancelled
    else { return }
    withAnimation(.easeOut(duration: 0.2)) {
      image = representation.cgImage
    }
  }
}

/// Colors that tie a storage category's chart segment, legend dot, and icon together.
public enum StorageCategoryStyle {
  public static func color(_ category: StorageCategory) -> Color {
    switch category {
      case .photos: .blue
      case .videos: .purple
      case .files: .orange
      case .voice: .pink
      case .other: .teal
    }
  }

  public static let databaseColor = Color.gray
}
