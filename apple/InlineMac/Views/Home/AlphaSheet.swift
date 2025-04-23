import InlineKit
import SwiftUI

struct AlphaCapsule: View {
  @State private var showingSheet = false

  var body: some View {
    Text("ALPHA")
      .monospaced()
      .foregroundStyle(.primary)
      .font(.caption)
      .fontWeight(.semibold)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background(
        Capsule()
          .strokeBorder(.primary, lineWidth: 1.0)
      )
      .opacity(0.5)
      .onTapGesture {
        showingSheet = true
      }
      .sheet(isPresented: $showingSheet) {
        AlphaInfoSheet()
      }
  }
}

struct AlphaInfoSheet: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage("alphaText") private var text: String = ""

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text(.init(text))
          .font(.body)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: 320)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .task {
        do {
          text = try await ApiClient.shared.getAlphaText()
        } catch {}
      }
    }
    .presentationDetents([.medium])
  }
}
