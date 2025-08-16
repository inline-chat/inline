import SwiftUI
import Logger

struct DebugView: View {
  @State private var isClearing = false
  @State private var showClearAlert = false
  @State private var clearError: Error?
  @State private var showClearError = false
  
  var body: some View {
    List {
      Section("Shared Data") {
        Button {
          showClearAlert = true
        } label: {
          SettingsItem(
            icon: "trash.fill",
            iconColor: .red,
            title: "Clear Shared Data"
          ) {
            if isClearing {
              ProgressView()
                .padding(.trailing, 8)
            }
          }
        }
        .disabled(isClearing)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Debug")
    .navigationBarTitleDisplayMode(.inline)
    .alert("Clear Shared Data", isPresented: $showClearAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        clearSharedData()
      }
    } message: {
      Text("This will clear all shared data used by the share extension. The data will be regenerated when needed.")
    }
    .alert("Error Clearing Data", isPresented: $showClearError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(clearError?.localizedDescription ?? "An unknown error occurred")
    }
  }
  
  private func clearSharedData() {
    isClearing = true
    
    Task {
      do {
        try BridgeManager.shared.clearSharedData()
        await MainActor.run {
          isClearing = false
        }
      } catch {
        await MainActor.run {
          clearError = error
          showClearError = true
          isClearing = false
        }
      }
    }
  }
}

#Preview("Debug") {
  NavigationView {
    DebugView()
  }
}