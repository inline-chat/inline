import SwiftUI

struct NotionTaskLoadingSheet: View {
  var body: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(0.8)

      Text("Creating Notion task...")
        .font(.system(size: 13))
        .foregroundColor(.secondary)
    }
    .padding(32)
    .frame(width: 280, height: 120)
    .background(Color(NSColor.windowBackgroundColor))
  }
}
