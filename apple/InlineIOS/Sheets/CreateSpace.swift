import InlineKit
import SwiftUI

struct CreateSpace: View {
  @State private var animate: Bool = false
  @State private var name = ""
  @FocusState private var isFocused: Bool
  @FormState var formState

  @EnvironmentObject var nav: Navigation
  @Environment(\.appDatabase) var database
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var dataManager: DataManager

  @Binding var showSheet: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      AnimatedLabel(animate: $animate, text: "Create Space")

      TextField("eg. Acme HQ", text: $name)
        .focused($isFocused)
        .keyboardType(.emailAddress)
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
        .onSubmit {
          submit()
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
          submit()
        }
        .buttonStyle(SimpleButtonStyle())
        .padding(.horizontal, OnboardingUtils.shared.hPadding)
        .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
        .disabled(name.isEmpty)
        .opacity(name.isEmpty ? 0.5 : 1)
      }
    }
  }

  func submit() {
    Task {
      do {
        formState.startLoading()
        let id = try await dataManager.createSpace(name: name)

        formState.succeeded()
        showSheet = false

        if let id {
          nav.push(.space(id: id))
        }

      } catch {
        // TODO: handle error
        Log.shared.error("Failed to create space", error: error)
      }
      dismiss()
    }
  }
}
