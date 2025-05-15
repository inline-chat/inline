import SwiftUI

struct BackToSpacesButton: View {
  @Binding var selectedSpaceId: Int64?

  var body: some View {
    Button {
      selectedSpaceId = nil
    } label: {
      Image(systemName: "chevron.left")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
  }
}

#Preview {
  BackToSpacesButton(selectedSpaceId: .constant(1))
}
