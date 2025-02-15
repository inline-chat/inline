import InlineKit
import Logger
import SwiftUI

enum UsernameStatus {
  case checking
  case available
  case taken
}

struct Profile: View {
  // MARK: - State

  @State private var fullName = ""
  @State private var username = ""
  @State private var animate = false
  @State private var errorMsg = ""
  @State private var isInputValid = false
  @State private var usernameStatus: UsernameStatus = .checking

  // MARK: - Focus Management

  enum Field: Hashable {
    case fullName
    case username
  }

  @FocusState private var focusedField: Field?

  // MARK: - Environment

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var api: ApiClient
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @Environment(\.auth) private var auth
  @Environment(\.appDatabase) private var database
  @FormState private var formState

  // MARK: - Constants

  private let placeHolder = "Name"

  // MARK: - Body

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      nameSection
      usernameSection
      errorSection
    }
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .safeAreaInset(edge: .bottom) { bottomButton }
    .onChange(of: fullName) { validateInput() }
    .onChange(of: username) { validateInput() }
    .onAppear { focusedField = .fullName }
  }
}

// MARK: - Helper Methods

extension Profile {
  private func handleUsernameChange(_ newValue: String) {
    errorMsg = ""
    let trimmedUsername = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

    if !trimmedUsername.isEmpty, trimmedUsername.count >= 2 {
      checkUsername(trimmedUsername)
    } else {
      usernameStatus = .checking
    }
  }

  private func checkUsername(_ username: String) {
    Task {
      do {
        usernameStatus = .checking
        try? await Task.sleep(for: .seconds(0.5))
        let result = try await api.checkUsername(username: username)

        withAnimation(.smooth(duration: 0.15)) {
          usernameStatus = result.available ? .available : .taken
        }
      } catch {
        Log.shared.error("Failed to check username", error: error)
      }
    }
  }

  private func validateInput() {
    errorMsg = ""
    isInputValid = !fullName.isEmpty && !username.isEmpty && usernameStatus == .available
  }

  private func submitAccount() {
    Task {
      do {
        formState.startLoading()
        guard !fullName.isEmpty else {
          errorMsg = "Please enter your name"
          formState.reset()
          return
        }

        let (firstName, lastName) = parseNameComponents(from: fullName)
        let result = try await api.updateProfile(
          firstName: firstName,
          lastName: lastName,
          username: username.lowercased()
        )

        print(result.user)
        try await database.dbWriter.write { db in
          try User(from: result.user).save(db)
        }
        mainViewRouter.setRoute(route: .main)
        formState.reset()
        nav.push(.main)
      } catch {
        Log.shared.error("Failed to create user", error: error)
        errorMsg = "Failed to create account. Please try again."
        formState.reset()
        isInputValid = false
      }
    }
  }

  private func parseNameComponents(from fullName: String) -> (firstName: String, lastName: String?) {
    let formatter = PersonNameComponentsFormatter()
    if let components = formatter.personNameComponents(from: fullName) {
      if components.givenName == nil {
        return (fullName, nil)
      }
      return (components.givenName ?? fullName, components.familyName)
    }
    return (fullName, nil)
  }
}

// MARK: - Views

extension Profile {
  @ViewBuilder
  private var nameSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      AnimatedLabel(animate: $animate, text: "Setup your profile")
      TextField(placeHolder, text: $fullName)
        .focused($focusedField, equals: .fullName)
        .textContentType(.name)
        .textInputAutocapitalization(.words)
        .font(.title2)
        .fontWeight(.semibold)
        .padding(.vertical, 8)
        .onChange(of: focusedField) { _, newValue in
          withAnimation(.smooth(duration: 0.15)) {
            animate = newValue == .fullName
          }
        }
        .onSubmit { focusedField = .username }
    }
  }

  @ViewBuilder
  private var usernameSection: some View {
    TextField("Username", text: $username)
      .focused($focusedField, equals: .username)
      .textContentType(.username)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled(true)
      .font(.title2)
      .fontWeight(.semibold)
      .padding(.vertical, 8)
      .onChange(of: username) { _, newValue in
        handleUsernameChange(newValue)
      }
      .overlay(alignment: .trailing) {
        usernameStatusIndicator
      }
      .onSubmit { submitAccount() }
  }

  @ViewBuilder
  private var usernameStatusIndicator: some View {
    if username.count >= 2 {
      switch usernameStatus {
        case .checking:
          Image(systemName: "hourglass")
            .font(.callout)
            .foregroundColor(.secondary)
        case .available:
          Image(systemName: "checkmark.circle")
            .font(.callout)
            .foregroundColor(.green)
        case .taken:
          Image(systemName: "xmark.circle")
            .font(.callout)
            .foregroundColor(.red)
      }
    }
  }

  private var errorSection: some View {
    Text(errorMsg)
      .font(.callout)
      .foregroundColor(.red)
      .padding(.top, 8)
  }

  @ViewBuilder
  private var bottomButton: some View {
    Button(formState.isLoading ? "Creating Account..." : "Continue") {
      submitAccount()
    }
    .buttonStyle(SimpleButtonStyle())
    .frame(maxWidth: .infinity)
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    .disabled(formState.isLoading)
    .opacity(formState.isLoading ? 0.5 : 1)
  }
}

#Preview {
  Profile()
}
