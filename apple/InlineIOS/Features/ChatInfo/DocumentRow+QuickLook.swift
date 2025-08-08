import Logger
import QuickLook
import SwiftUI

extension DocumentRow {
  @ViewBuilder
  var quickLookPreview: some View {
    if canPreview, let url = documentURL {
      QuickLookPreview(url: url, isPresented: $showingQuickLook)
    } else {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 48))
          .foregroundColor(.orange)
        
        Text("Cannot preview document")
          .font(.title2)
          .fontWeight(.medium)
        
        Text("The document is not available for preview. Please try downloading it again.")
          .font(.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
        
        Button("OK") {
          showingQuickLook = false
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
    }
  }
}
