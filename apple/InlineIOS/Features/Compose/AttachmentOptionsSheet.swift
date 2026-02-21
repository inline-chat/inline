import SwiftUI

enum AttachmentOption {
  case library
  case camera
  case file
}

struct AttachmentOptionsSheet: View {
  let onSelect: (AttachmentOption) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Attach")
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)

      optionButton(title: "Library", icon: "photo.on.rectangle.angled", option: .library)
      optionButton(title: "Camera", icon: "camera", option: .camera)
      optionButton(title: "File", icon: "folder", option: .file)
    }
    .padding(16)
    .presentationDragIndicator(.visible)
    .background(Color(UIColor.systemBackground))
  }

  private func optionButton(title: String, icon: String, option: AttachmentOption) -> some View {
    Button {
      onSelect(option)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 24)
        Text(title)
          .font(.system(size: 17, weight: .medium))
        Spacer()
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .background(Color(UIColor.secondarySystemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}
