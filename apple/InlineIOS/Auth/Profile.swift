import Auth
import InlineKit
import Logger
import RealtimeV2
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
  @State private var hasHydratedProfile = false

  // MARK: - Focus Management

  enum Field: Hashable {
    case fullName
    case username
  }

  @FocusState private var focusedField: Field?

  // MARK: - Environment

  @EnvironmentObject private var nav: Navigation
  @EnvironmentObject private var mainViewRouter: MainViewRouter
  @Environment(\.auth) private var auth
  @Environment(\.appDatabase) private var database
  @Environment(\.realtimeV2) private var realtimeV2
  @FormState private var formState

  // MARK: - Constants

  private let placeHolder = "Name"

  // MARK: - Body

  var body: some View {
    Group {
      if hasHydratedProfile {
        VStack(spacing: 20) {
          Spacer()

          // Icon and title section
          VStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
              .resizable()
              .scaledToFit()
              .frame(width: 34, height: 34)
              .foregroundColor(.primary)

            Text(NSLocalizedString("Setup your profile", comment: "Profile setup title"))
              .font(.onboardingIOSTitle.weight(.medium))
              .foregroundStyle(.primary)
          }

          // Input fields
          VStack(spacing: 8) {
            nameSection
            usernameSection

            if !errorMsg.isEmpty {
              Text(errorMsg)
                .font(.callout)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.horizontal, OnboardingUtils.shared.hPadding)

          Spacer()
        }
        .safeAreaInset(edge: .bottom) { bottomButton }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onChange(of: fullName) { validateInput() }
    .onChange(of: username) { validateInput() }
    .task { await hydratePersistedProfile() }
  }
}

// MARK: - Helper Methods

extension Profile {
  @MainActor
  private func hydratePersistedProfile() async {
    defer {
      hasHydratedProfile = true
      focusedField = .fullName
      validateInput()
    }
    guard let userID = auth.getCurrentUserId() else { return }
    do {
      let user = try await User.fetch(id: userID, from: database)
      guard let user else { return }
      if fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        fullName = user.fullName
      }
      if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        username = user.username ?? ""
      }
    } catch {
      Log.shared.error("Failed to load persisted onboarding profile", error: error)
    }
  }

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
        let result = try await realtimeV2.checkUsername(username)

        withAnimation(.smooth(duration: 0.15)) {
          usernameStatus = switch result.availability {
          case .usernameAvailable, .usernameCurrent: .available
          case .usernameTaken, .usernameReserved, .usernameInvalid: .taken
          case .unspecified, .UNRECOGNIZED: .checking
          }
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
        let profile = try await realtimeV2.updateProfile(
          firstName: firstName,
          lastName: lastName,
          bio: nil
        )
        await realtimeV2.applyUpdates(profile.updates)
        let usernameResult = try await realtimeV2.changeUsername(username.lowercased())
        await realtimeV2.applyUpdates(usernameResult.updates)
        try await database.dbWriter.write { db in
          try User(from: usernameResult.user).save(db)
        }
        nav.reset()
        mainViewRouter.setRoute(route: .main)
        formState.reset()
      } catch let error as APIError {
        OnboardingUtils.shared.showError(error: error, errorMsg: $errorMsg)
        formState.reset()
        isInputValid = false
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
    TextField(placeHolder, text: $fullName)
      .focused($focusedField, equals: .fullName)
      .textContentType(.name)
      .textInputAutocapitalization(.words)
      .font(.body)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                focusedField == .fullName ? Color.accentColor : Color.onboardingSystemGray4,
                lineWidth: focusedField == .fullName ? 2 : 0.5
              )
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .animation(.easeInOut(duration: 0.2), value: focusedField)
      .onSubmit { focusedField = .username }
  }

  @ViewBuilder
  private var usernameSection: some View {
    TextField("Username", text: $username)
      .focused($focusedField, equals: .username)
      .textContentType(.username)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled(true)
      .font(.body)
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(
        RoundedRectangle(cornerRadius: 16)
          .fill(.ultraThinMaterial)
          .overlay(
            RoundedRectangle(cornerRadius: 16)
              .stroke(
                focusedField == .username ? Color.accentColor : Color.onboardingSystemGray4,
                lineWidth: focusedField == .username ? 2 : 0.5
              )
          )
      )
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .animation(.easeInOut(duration: 0.2), value: focusedField)
      .onChange(of: username) { _, newValue in
        handleUsernameChange(newValue)
      }
      .overlay(alignment: .trailing) {
        usernameStatusIndicator
          .padding(.trailing, 20)
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

  @ViewBuilder
  private var bottomButton: some View {
    Button(formState.isLoading ? "Creating Account..." : "Continue") {
      submitAccount()
    }
    .buttonStyle(OnboardingAccentButtonStyle())
    .frame(maxWidth: .infinity)
    .padding(.horizontal, OnboardingUtils.shared.hPadding)
    .padding(.bottom, OnboardingUtils.shared.buttonBottomPadding)
    .disabled(formState.isLoading)
    .opacity(formState.isLoading ? 0.5 : 1)
  }
}

#Preview("Profile - Light Mode") {
  Profile()
    .preferredColorScheme(.light)
    .environmentObject(Navigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("Profile - Dark Mode") {
  Profile()
    .preferredColorScheme(.dark)
    .environmentObject(Navigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
}

#Preview("Profile - Compact") {
  Profile()
    .preferredColorScheme(.light)
    .environmentObject(Navigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
    .previewDevice("iPhone SE (3rd generation)")
}

#Preview("Profile - Large Text") {
  Profile()
    .preferredColorScheme(.light)
    .environmentObject(Navigation())
    .environmentObject(ApiClient.shared)
    .environmentObject(MainViewRouter())
    .environment(\.appDatabase, AppDatabase.empty())
    .environment(\.sizeCategory, .accessibilityExtraExtraExtraLarge)
}
