#if os(iOS)
import SwiftUI

public struct LimitedLibraryNotice: View {
  private let action: () -> Void
  @State private var isPresentingAccessAlert = false

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  public var body: some View {
    Button(action: {
      isPresentingAccessAlert = true
    }) {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Text("Limited photos access")
          .font(.subheadline.weight(.regular))
          .foregroundStyle(.secondary)

        Image(systemName: "exclamationmark.circle")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.trailing, 20)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .alert("Inline Would Like To Access Your Photos", isPresented: $isPresentingAccessAlert) {
      Button("Select More Photos...") {
        action()
      }
      Button("Keep Current Selection", role: .cancel) {}
    } message: {
      Text("This lets you send photos from your library to Inline.")
    }
    .accessibilityLabel("Limited photos access")
    .accessibilityHint("Shows options to keep the current selection or select more photos")
  }
}
#endif
