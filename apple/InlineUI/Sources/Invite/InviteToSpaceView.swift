import InlineKit
import InlineProtocol
import SwiftUI
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

public struct InviteToSpaceView: View {
  @Environment(\.appDatabase) var db
  @Environment(\.realtime) var realtime
  @Environment(\.realtimeV2) var realtimeV2
  @Environment(\.dismiss) private var dismiss

  @FormState var formState
  @StateObject private var search = SpaceInviteSearchViewModel()
  @State private var searchQuery = ""
  @State private var emailInput = ""
  @State private var phoneInput = ""
  @State private var selectedInviteType: InviteType = .username
  @State private var selectedAccessLevel: AccessLevel = .member
  @State private var canAccessPublicThreads: Bool = true
  @State private var showInviteConfirmation = false
  @State private var selectedUser: ApiUser?
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var showSuccess = false
  @State private var successMessage = ""
  @State private var showPhoneShare = false

  private let spaceId: Int64
  private let onManageMembers: (() -> Void)?
  @StateObject private var spaceViewModel: FullSpaceViewModel
  @StateObject private var membershipStatusViewModel: SpaceMembershipStatusViewModel

  enum InviteType {
    case username
    case email
    case phone
  }

  enum AccessLevel {
    case admin
    case member
  }

  public init(spaceId: Int64, onManageMembers: (() -> Void)? = nil) {
    self.spaceId = spaceId
    self.onManageMembers = onManageMembers
    _spaceViewModel = StateObject(wrappedValue: FullSpaceViewModel(db: AppDatabase.shared, spaceId: spaceId))
    _membershipStatusViewModel = StateObject(
      wrappedValue: SpaceMembershipStatusViewModel(db: AppDatabase.shared, spaceId: spaceId)
    )
  }

  public var body: some View {
    mainForm
      .formStyle(.grouped)
      .padding()
      .scrollContentBackground(.hidden)
      .confirmationDialog(
        "Invite \(selectedUser?.anyName ?? "") to \(spaceViewModel.space?.name ?? "")?",
        isPresented: $showInviteConfirmation,
        titleVisibility: .visible
      ) {
        Button("Invite") {
          sendUsernameInvite()
        }
        Button("Cancel", role: .cancel) {
          selectedUser = nil
        }
      }
      .alert("Error", isPresented: $showError) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage)
      }
      .alert("Success", isPresented: $showSuccess) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(successMessage)
      }
      .task {
        await membershipStatusViewModel.refreshIfNeeded()
      }
      .sheet(isPresented: $showPhoneShare) {
        phoneShareView
      }
  }

  private var mainForm: some View {
    Form {
      titleSection
      manageMembersSection
      inviteTypeSection
      inviteRoleSection
      inputSection
      if selectedInviteType == .username {
        searchResultsSection
      }
    }
  }

  @ViewBuilder
  private var titleSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          Image(systemName: "person.badge.plus")
            .foregroundStyle(.blue)
          Text("Invite to \(spaceViewModel.space?.name ?? "")")
            .font(.headline)
        }

        Text(
          "Invite people by email or username if already on the app. They will get access to public threads and you can add them to private threads after invite."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 4)
    }
  }

  private var phoneShareView: some View {
    VStack(spacing: 16) {
      Text("Share Invite")
        .font(.headline)
        .padding(.top)

      Text(
        "I invited you to \"\(spaceViewModel.space?.name ?? "")\" on Inline to chat with me.\nIf you don't have the app, get it from TestFlight for iOS and be sure to sign up with this phone number: \(phoneInput).\nhttps://testflight.apple.com/join/FkC3f7fz (Video installation guide: https://www.loom.com/share/73f951f0963843f588c921751ac82603)"
      )
      .font(.body) 
      .multilineTextAlignment(.leading)
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.secondary.opacity(0.1))
      .cornerRadius(8)

      HStack(spacing: 12) {
        Button(action: {
          let text =
            "I invited you to \"\(spaceViewModel.space?.name ?? "")\" on Inline to chat with me.\nIf you don't have the app, get it from TestFlight for iOS and be sure to sign up with this phone number: \(phoneInput).\nhttps://testflight.apple.com/join/FkC3f7fz (Video installation guide: https://www.loom.com/share/73f951f0963843f588c921751ac82603)"
          #if canImport(AppKit)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          #endif
        }) {
          Label("Copy", systemImage: "doc.on.doc")
        }

        ShareLink(
          item: "I invited you to \"\(spaceViewModel.space?.name ?? "")\" on Inline to chat with me.\nIf you don't have the app, get it from TestFlight for iOS and be sure to sign up with this phone number: \(phoneInput).\nhttps://testflight.apple.com/join/FkC3f7fz",
          subject: Text("Join me on Inline"),
          message: Text("I invited you to chat on Inline")
        ) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }
      .padding(.bottom)
    }
    .padding()
    .frame(width: 400)
  }

  @ViewBuilder
  private var manageMembersSection: some View {
    #if os(macOS)
    if let onManageMembers, membershipStatusViewModel.canManageMembers {
      Section {
        Button {
          onManageMembers()
        } label: {
          Label("Manage Members", systemImage: "person.3")
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.link)
      }
    }
    #endif
  }

  @ViewBuilder
  private var inviteTypeSection: some View {
    Section {
      Picker("Invite via", selection: $selectedInviteType) {
        Text("Username").tag(InviteType.username)
        Text("Email").tag(InviteType.email)
        Text("Phone").tag(InviteType.phone)
      }
      .pickerStyle(SegmentedPickerStyle())
    }
  }

  @ViewBuilder
  private var inviteRoleSection: some View {
    Section {
      Picker("Access Level", selection: $selectedAccessLevel) {
        Text("Member").tag(AccessLevel.member)
        Text("Admin").tag(AccessLevel.admin)
      }
      .pickerStyle(.menu)

      if selectedAccessLevel == AccessLevel.member {
        Toggle(isOn: $canAccessPublicThreads) {
          Text("Has access to all public chats")
        }
      }
    }
  }

  private var access: InviteToSpaceTransaction.Context.AccessRole {
    switch selectedAccessLevel {
      case .admin:
        .admin
      case .member:
        .member(canAccessPublicChats: canAccessPublicThreads)
    }
  }

  @ViewBuilder var inputSectionField: some View {
    if selectedInviteType == .username {
      TextField(
        "Search by username",
        text: $searchQuery,
        prompt: Text("Enter username to search")
      )
      .textFieldStyle(.automatic)
      .font(.body)
      .onChange(of: searchQuery) { _, newValue in
        Task {
          await search.search(query: newValue)
        }
      }
    } else if selectedInviteType == .email {
      TextField(
        "Email address",
        text: $emailInput,
        prompt: Text("Enter email address")
      )
      .textFieldStyle(.automatic)
      .font(.body)
      .submitLabel(.send)
      .onSubmit {
        if !emailInput.isEmpty, isValidEmail(emailInput) {
          sendEmailInvite()
        }
      }

      Button(action: sendEmailInvite) {
        HStack {
          Spacer()
          Text("Send Invite")
          Spacer()
        }
      }
      .disabled(emailInput.isEmpty || !isValidEmail(emailInput))
    } else {
      TextField(
        "Phone number",
        text: $phoneInput,
        prompt: Text("Enter phone number (e.g. +441234567891)")
      )
      .textFieldStyle(.automatic)
      .font(.body)
      .submitLabel(.send)
      .onSubmit {
        if !phoneInput.isEmpty, isValidPhone(phoneInput) {
          sendPhoneInvite()
        }
      }

      Button(action: sendPhoneInvite) {
        HStack {
          Spacer()
          Text("Create Invite")
          Spacer()
        }
      }
      .disabled(phoneInput.isEmpty || !isValidPhone(phoneInput))
    }
  }

  @ViewBuilder
  private var inputSection: some View {
    Section {
      inputSectionField
    }
  }

  private var searchResultsSection: some View {
    Section {
      if search.isLoading {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Searching...")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 4)
      } else if !search.results.isEmpty {
        ForEach(search.results, id: \.id) { user in
          RemoteUserItem(user: user, action: {
            selectedUser = user
            showInviteConfirmation = true
          })
          .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
        }
      } else if !searchQuery.isEmpty {
        Text("No users found")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func sendEmailInvite() {
    Task {
      do {
        formState.startLoading()
        try await realtimeV2.send(
          .inviteToSpace(
            spaceId: spaceId,
            access: access,
            email: emailInput,
          )
        )
        formState.succeeded()
        successMessage = "Invite sent to \(emailInput)"
        showSuccess = true
        emailInput = ""
        dismiss()
      } catch let error as RealtimeAPIError {
        formState.failed(error: "")
        handleInviteError(error)
      } catch {
        formState.failed(error: error.localizedDescription)
        showError(message: error.localizedDescription)
      }
    }
  }

  private func sendUsernameInvite() {
    guard let user = selectedUser else { return }

    Task {
      do {
        formState.startLoading()
        try await realtimeV2.send(
          .inviteToSpace(
            spaceId: spaceId,
            access: access,
            userId: user.id,
          )
        )
        formState.succeeded()
        successMessage = "Invite sent to \(user.anyName)"
        showSuccess = true
        searchQuery = ""
        selectedUser = nil
        dismiss()
      } catch let error as RealtimeAPIError {
        formState.failed(error: "")
        handleInviteError(error)
      } catch {
        formState.failed(error: error.localizedDescription)
        showError(message: error.localizedDescription)
      }
    }
  }

  private func sendPhoneInvite() {
    Task {
      do {
        formState.startLoading()
        try await realtimeV2.send(
          .inviteToSpace(
            spaceId: spaceId,
            access: access,
            phoneNumber: phoneInput,
          )
        )
        formState.succeeded()
        showPhoneShare = true
      } catch let error as RealtimeAPIError {
        formState.failed(error: "")
        handleInviteError(error)
      } catch {
        formState.failed(error: error.localizedDescription)
        showError(message: error.localizedDescription)
      }
    }
  }

  private func handleInviteError(_ error: RealtimeAPIError) {
    switch error {
      case let .rpcError(errorCode, message, _):
        switch errorCode {
          case .userIDInvalid:
            showError(message: "Invalid user selected")
          case .userAlreadyMember:
            showError(message: "User is already a member of this space")
          case .emailInvalid:
            showError(message: "Invalid email address")
          default:
            showError(message: message ?? "Failed to send invite")
        }
      case .notAuthorized:
        showError(message: "You are not authorized to invite members")
      case .notConnected:
        showError(message: "Not connected to server")
      case .stopped:
        showError(message: "Connection stopped")
      case let .unknown(error):
        showError(message: error.localizedDescription)
    }
  }

  private func showError(message: String) {
    errorMessage = message
    showError = true
  }

  private func isValidEmail(_ email: String) -> Bool {
    let emailRegEx = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
    let emailPred = NSPredicate(format: "SELF MATCHES %@", emailRegEx)
    return emailPred.evaluate(with: email)
  }

  private func isValidPhone(_ phone: String) -> Bool {
    // Basic validation for international phone numbers
    // Must start with + and contain only digits after that
    let phoneRegex = "^\\+[0-9]{8,15}$"
    let phonePred = NSPredicate(format: "SELF MATCHES %@", phoneRegex)
    return phonePred.evaluate(with: phone)
  }
}

#Preview {
  InviteToSpaceView(spaceId: 1)
    .previewsEnvironment(.populated)
}
