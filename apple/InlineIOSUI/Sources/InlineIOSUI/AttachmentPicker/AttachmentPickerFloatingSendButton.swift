#if os(iOS)
import SwiftUI

struct AttachmentPickerFloatingSendButton: View {
  let title: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    .attachmentPickerPrimaryButtonStyle()
  }
}

private extension View {
  @ViewBuilder
  func attachmentPickerPrimaryButtonStyle() -> some View {
    if #available(iOS 26.0, *) {
      self
        .buttonStyle(.glassProminent)
    } else {
      self
        .buttonStyle(.borderedProminent)
        .clipShape(Capsule())
    }
  }
}
#endif
