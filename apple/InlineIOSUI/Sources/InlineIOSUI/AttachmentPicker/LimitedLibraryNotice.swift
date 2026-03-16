#if os(iOS)
import SwiftUI

public struct LimitedLibraryNotice: View {
  private let action: () -> Void

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.orange)

        Text("Limited photos access")
          .font(.subheadline.weight(.regular))
          .foregroundStyle(.primary)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .attachmentPickerSurface(cornerRadius: 18, interactive: true)
    .accessibilityLabel("Limited photos access")
    .accessibilityHint("Select more photos to give Inline access")
  }
}
#endif
