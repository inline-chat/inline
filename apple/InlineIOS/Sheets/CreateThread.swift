import InlineKit
import SwiftUI

struct CreateThread: View {
  @State private var animate: Bool = false
  @State private var name = ""
  @FocusState private var isFocused: Bool
  @FormState var formState

  @EnvironmentObject var nav: Navigation
  @Environment(\.appDatabase) var database
  @EnvironmentObject var dataManager: DataManager

  @Binding var showSheet: Bool
  var spaceId: Int64

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      AnimatedLabel(animate: $animate, text: "Create Thread")

      TextField("eg. ideas", text: $name)
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.vertical, 8)
        .onChange(of: isFocused) { _, newValue in
          withAnimation(.smooth(duration: 0.15)) {
            animate = newValue
          }
        }
    }
    .onAppear {
      isFocused = true
    }
    .padding(.horizontal, 50)
    .frame(maxHeight: .infinity)
    .safeAreaInset(edge: .bottom) {
      VStack {
        Button(formState.isLoading ? "Creating..." : "Create") {
          Task {
            do {
              formState.startLoading()
              let threadId = try await dataManager.createThread(spaceId: spaceId, title: name)
              formState.succeeded()
              showSheet = false
              if let threadId = threadId {
                nav.push(.chat(peer: .thread(id: threadId)))
              }
            } catch {
              Log.shared.error("Failed to create space", error: error)
            }
          }
        }
        .buttonStyle(SimpleButtonStyle())
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
        .disabled(name.isEmpty)
        .opacity(name.isEmpty ? 0.5 : 1)
      }
    }
  }
}
