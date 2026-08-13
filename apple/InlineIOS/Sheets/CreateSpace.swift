import InlineKit
import InlineUI
import Logger
import SwiftUI

struct CreateSpace: View {
  @State private var name = ""
  @State private var emoji = ""
  @FocusState private var focusedField: Field?
  @FormState var formState
  @AppStorage(ExperimentalHomePreferenceKeys.isEnabled)
  private var enableExperimentalView = false

  @Environment(\.dismiss) private var dismiss
  @Environment(Router.self) private var router
  @EnvironmentObject private var dataManager: DataManager

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            emojiField

            TextField("Space name", text: $name)
              .focused($focusedField, equals: .name)
              .textInputAutocapitalization(.words)
              .submitLabel(.done)
              .onSubmit {
                submit()
              }
          }
        } footer: {
          Text("Choose a short name and an optional emoji. You can change both later.")
        }

        if let error = formState.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Create Space")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(formState.isLoading)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button {
            submit()
          } label: {
            if formState.isLoading {
              ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Creating Space")
            } else {
              Text("Create")
            }
          }
          .disabled(trimmedName.isEmpty || formState.isLoading)
        }
      }
      .onAppear {
        focusedField = .name
      }
    }
    .interactiveDismissDisabled(formState.isLoading)
  }

  private var emojiField: some View {
    ZStack {
      Circle()
        .fill(Color.accentColor.opacity(0.12))

      if emoji.isEmpty {
        Image(systemName: "face.smiling")
          .font(.title2)
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }

      TextField("", text: $emoji)
        .focused($focusedField, equals: .emoji)
        .keyboardType(.emoji ?? .default)
        .font(.title2)
        .multilineTextAlignment(.center)
        .textFieldStyle(.plain)
        .accessibilityLabel("Space emoji")
        .onChange(of: emoji) { _, newValue in
          guard let firstCharacter = newValue.first else { return }
          let firstEmoji = String(firstCharacter)
          if emoji != firstEmoji {
            emoji = firstEmoji
          }
          focusedField = .name
        }
    }
    .frame(width: 48, height: 48)
    .contentShape(Circle())
    .onTapGesture {
      focusedField = .emoji
    }
  }

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func submit() {
    let spaceName = trimmedName
    guard !spaceName.isEmpty, !formState.isLoading else { return }

    Task {
      do {
        formState.startLoading()
        let displayName = emoji.isEmpty ? spaceName : "\(emoji) \(spaceName)"
        let id = try await dataManager.createSpace(name: displayName)

        formState.succeeded()
        if let id {
          routeToCreatedSpace(id)
        }
        dismiss()
      } catch {
        Log.shared.error("Failed to create space", error: error)
        formState.failed(error: error.localizedDescription)
      }
    }
  }

  private func routeToCreatedSpace(_ id: Int64) {
    if enableExperimentalView {
      let targetTab = router.selectedTab.experimentalHomeFallbackTab
      if router.selectedTab != targetTab {
        router.selectedTab = targetTab
      }
      router.popToRoot(for: targetTab)
      router.push(.space(id: id), for: targetTab)
    } else {
      router.popToRoot(for: .spaces)
      router.selectedTab = .spaces
      router.push(.space(id: id), for: .spaces)
    }
  }

  private enum Field: Hashable {
    case emoji
    case name
  }
}
