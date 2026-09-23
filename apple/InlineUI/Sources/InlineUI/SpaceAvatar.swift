import InlineKit
import Kingfisher
import SwiftUI

public struct SpaceAvatar: View {
  let space: Space
  let size: CGFloat
  private let cornerRadius: CGFloat

  public init(space: Space, size: CGFloat = 32, cornerRadius: CGFloat? = nil) {
    self.space = space
    self.size = size
    self.cornerRadius = cornerRadius ?? size / 3
  }

  public var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.gray.opacity(0.15))
      if let value = space.photoURL, let url = URL(string: value) {
        KFImage(source: .network(ImageResource(downloadURL: url, cacheKey: space.photoFileUniqueId ?? value)))
          .placeholder { initials }
          .resizable()
          .scaledToFill()
      } else {
        initials
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .accessibilityLabel("\(space.displayName) space picture")
  }

  private var initials: some View {
    let text = SpaceAvatarContent.text(for: space)
    return Text(text)
      .font(.system(size: size * SpaceAvatarContent.fontScale(for: text), weight: .semibold))
      .foregroundStyle(.secondary)
  }
}
