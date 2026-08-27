#if os(iOS)
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

private enum InviteIOSRoute: Hashable {
  case options
  case destination
  case outcome
}

struct InviteIOSView: View {
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.realtimeV2) private var realtime
  @State private var path: [InviteIOSRoute] = []

  var body: some View {
    NavigationStack(path: $path) {
      InviteIOSSelectionScreen(
        model: model,
        realtime: realtime,
        onCancel: { dismiss() },
        onNext: { path.append(.options) }
      )
      .navigationDestination(for: InviteIOSRoute.self) { route in
        switch route {
        case .options:
          InviteIOSOptionsScreen(
            model: model,
            onComplete: { path.append(.outcome) }
          )
        case .destination:
          InviteIOSDestinationPicker(model: model)
        case .outcome:
          InviteIOSOutcomeScreen(
            model: model,
            onOpenChat: onOpenChat,
            onInviteMore: {
              model.returnToInvite()
              path = []
            },
            onDone: { dismiss() }
          )
        }
      }
    }
  }
}

// MARK: - Selection

private struct InviteIOSSelectionScreen: View {
  let model: InviteComposerModel
  let realtime: RealtimeV2
  let onCancel: () -> Void
  let onNext: () -> Void

  @FocusState private var searchIsFocused: Bool

  var body: some View {
    InviteIOSSelectionContent(
      model: model,
      onDismissKeyboard: { searchIsFocused = false }
    )
    .modifier(
      InviteIOSTopBarModifier(
        content: InviteIOSSearchTopBar(
          model: model,
          searchIsFocused: $searchIsFocused
        )
      )
    )
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", action: onCancel)
      }
      ToolbarItem(placement: .principal) {
        InviteIOSNavigationTitle(
          destinationName: model.destinationName,
          isSpaceInvite: model.isSpaceInvite,
          selectedCount: model.selected.count
        )
      }
      ToolbarItemGroup(placement: .confirmationAction) {
        if case let .space(id) = model.destination {
          SpaceInviteLinkButton(spaceID: id, realtime: realtime)
            .id(id)
        }
        Button("Next") {
          searchIsFocused = false
          onNext()
        }
        .disabled(model.selected.isEmpty)
      }
    }
  }
}

private struct InviteIOSNavigationTitle: View {
  let destinationName: String?
  let isSpaceInvite: Bool
  let selectedCount: Int

  var body: some View {
    VStack(spacing: 0) {
      Text("Invite")
        .font(.headline)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private var subtitle: String {
    if selectedCount > 0 {
      return selectedCount == 1 ? "1 selected" : "\(selectedCount) selected"
    }
    return isSpaceInvite ? (destinationName ?? "to a space") : "to Inline"
  }
}

private struct InviteIOSTopBarModifier<BarContent: View>: ViewModifier {
  let content: BarContent

  @ViewBuilder
  func body(content host: Content) -> some View {
    if #available(iOS 26.0, *) {
      host.safeAreaBar(edge: .top, spacing: 0) {
        content
      }
    } else {
      host.safeAreaInset(edge: .top, spacing: 0) {
        content
          .background(.bar)
      }
    }
  }
}

private struct InviteIOSSearchTopBar: View {
  @Bindable var model: InviteComposerModel
  @FocusState.Binding var searchIsFocused: Bool

  var body: some View {
    VStack(spacing: 2) {
      if !model.selected.isEmpty {
        InviteIOSSelectedPeopleBar(
          targets: model.selected,
          onRemove: model.toggle
        )
      }
      InviteIOSSearchField(
        text: $model.query,
        isSearching: model.isSearching,
        contactsAreLoading: model.contactsState == .loading,
        isFocused: $searchIsFocused,
        onContacts: model.showContacts
      )
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .modifier(InviteIOSSearchFieldSurface())
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .animation(.spring(response: 0.4, dampingFraction: 0.84), value: model.selected.map(\.id))
  }
}

private struct InviteIOSSearchField: View {
  @Binding var text: String
  let isSearching: Bool
  let contactsAreLoading: Bool
  @FocusState.Binding var isFocused: Bool
  let onContacts: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Username, email, or phone", text: $text)
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textContentType(.none)
        .submitLabel(.search)
        .onSubmit { isFocused = false }

      if isSearching {
        ProgressView()
          .controlSize(.small)
      } else if !text.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          text = ""
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }

      Button("Find from Contacts", systemImage: "person.crop.circle.badge.plus") {
        isFocused = false
        onContacts()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .overlay {
        if contactsAreLoading {
          ProgressView()
            .controlSize(.mini)
            .background(.bar, in: Circle())
        }
      }
    }
    .padding(.horizontal, 2)
    .frame(minHeight: 38)
  }
}

private struct InviteIOSSearchFieldSurface: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    } else {
      content.background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 22))
    }
  }
}

private struct InviteIOSSelectedPeopleBar: View {
  let targets: [InviteTarget]
  let onRemove: (InviteTarget) -> Void

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(targets) { target in
          InviteIOSSelectionToken(target: target) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
              onRemove(target)
            }
          }
          .transition(.scale(scale: 0.84).combined(with: .opacity))
        }
      }
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
  }
}

private struct InviteIOSSelectionToken: View {
  let target: InviteTarget
  let onRemove: () -> Void

  var body: some View {
    Button(action: onRemove) {
      HStack(spacing: 6) {
        InviteIOSSmallArtwork(target: target)
        Text(target.title)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Image(systemName: "xmark.circle.fill")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.leading, 4)
      .padding(.trailing, 7)
      .frame(height: 30)
      .background(Color(.tertiarySystemFill), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove \(target.title)")
  }
}

private struct InviteIOSSelectionContent: View {
  let model: InviteComposerModel
  let onDismissKeyboard: () -> Void

  var body: some View {
    ZStack {
      InviteIOSResultsList(model: model)
      InviteIOSSelectionStatus(
        model: model,
        onDismissKeyboard: onDismissKeyboard
      )
    }
    .background(Color(.systemBackground))
  }
}

private struct InviteIOSResultsList: View {
  let model: InviteComposerModel

  var body: some View {
    List {
      InviteIOSCandidateSection(
        title: "Invite Users",
        targets: model.userTargets,
        model: model
      )
      InviteIOSCandidateSection(
        title: "Contacts",
        targets: model.contactTargets,
        model: model
      )
      InviteIOSCandidateSection(
        title: "Send Email Invite",
        targets: model.emailSuggestion.map { [$0] } ?? [],
        model: model
      )
      InviteIOSCandidateSection(
        title: "Invite Phone Number",
        targets: model.phoneTarget.map { [$0] } ?? [],
        model: model
      )
    }
    .listStyle(.plain)
    .listSectionSpacing(.compact)
    .contentMargins(.top, 2, for: .scrollContent)
    .scrollDismissesKeyboard(.interactively)
  }
}

private struct InviteIOSSelectionStatus: View {
  let model: InviteComposerModel
  let onDismissKeyboard: () -> Void

  var body: some View {
    ZStack {
      if !model.hasSuggestions {
        if model.isSearching {
          InviteIOSSearchingState()
        } else if let message = model.emptyResultMessage {
          InviteIOSNoResultsState(
            message: message,
            onDismissKeyboard: onDismissKeyboard
          )
        } else {
          InviteIOSEmptyState(
            isSpaceInvite: model.isSpaceInvite,
            destinationName: model.destinationName,
            onDismissKeyboard: onDismissKeyboard
          )
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(model.hasSuggestions ? Color.clear : Color(.systemBackground))
    .allowsHitTesting(!model.hasSuggestions)
  }
}

private struct InviteIOSCandidateSection: View {
  let title: LocalizedStringResource
  let targets: [InviteTarget]
  let model: InviteComposerModel

  var body: some View {
    if !targets.isEmpty {
      Section {
        ForEach(targets) { target in
          InviteIOSCandidateRow(
            target: target,
            isSelected: model.isSelected(target),
            onSelect: {
              withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
                model.selectFromResults(target)
              }
            }
          )
          .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
        }
      } header: {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(nil)
      }
    }
  }
}

private struct InviteIOSCandidateRow: View {
  let target: InviteTarget
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        InviteIOSCandidateArtwork(target: target)
        InviteIOSCandidateText(target: target)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .contentTransition(.symbolEffect(.replace))
          .symbolEffect(.bounce, value: isSelected)
      }
      .frame(minHeight: 40)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!target.isActionable)
    .opacity(target.isActionable ? 1 : 0.55)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct InviteIOSCandidateText: View {
  let target: InviteTarget

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(target.title)
        .font(.body)
        .foregroundStyle(.primary)
        .lineLimit(1)
      if let detail = target.detail {
        Text(detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct InviteIOSCandidateArtwork: View {
  let target: InviteTarget

  var body: some View {
    ZStack {
      switch target.kind {
      case let .user(info):
        UserAvatar(userInfo: info, size: 34)
      case .email, .phone:
        Circle()
          .fill(Color(.secondarySystemFill))
          .frame(width: 34, height: 34)
          .overlay {
            Image(systemName: target.symbol)
              .foregroundStyle(.secondary)
          }
      }
    }
  }
}

private struct InviteIOSSmallArtwork: View {
  let target: InviteTarget

  var body: some View {
    ZStack {
      switch target.kind {
      case let .user(info):
        UserAvatar(userInfo: info, size: 22)
      case .email, .phone:
        Image(systemName: target.symbol)
          .font(.caption)
          .frame(width: 22, height: 22)
          .background(Color(.secondarySystemFill), in: Circle())
      }
    }
  }
}

private struct InviteIOSEmptyState: View {
  let isSpaceInvite: Bool
  let destinationName: String?
  let onDismissKeyboard: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Invite People", systemImage: "person.badge.plus")
    } description: {
      Text(description)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: onDismissKeyboard)
  }

  private var description: String {
    if isSpaceInvite {
      return "Search for someone on Inline, or invite them by email or phone to \(destinationName ?? "this space")."
    }
    return "Search for someone on Inline, or invite them by email or phone. Create a space for a team or community."
  }
}

private struct InviteIOSSearchingState: View {
  var body: some View {
    ProgressView("Searching…")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct InviteIOSNoResultsState: View {
  let message: LocalizedStringResource
  let onDismissKeyboard: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.top, 28)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture(perform: onDismissKeyboard)
  }
}

// MARK: - Options

private struct InviteIOSOptionsScreen: View {
  let model: InviteComposerModel
  let onComplete: () -> Void

  @Environment(\.realtimeV2) private var realtime

  var body: some View {
    Form {
      InviteIOSSelectedPeopleSection(model: model)
      InviteIOSDestinationSection(model: model)
      if model.isSpaceInvite {
        InviteIOSAccessSection(model: model)
      }
    }
    .listSectionSpacing(.compact)
    .navigationTitle("Invite Options")
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled(model.isSending)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button {
          Task {
            if await model.invite(realtime: realtime) {
              onComplete()
            }
          }
        } label: {
          if model.isSending {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("Sending Invitations")
          } else {
            Text("Invite")
          }
        }
        .disabled(model.selected.isEmpty || model.isSending)
      }
    }
  }
}

private struct InviteIOSSelectedPeopleSection: View {
  let model: InviteComposerModel

  var body: some View {
    Section("People") {
      if model.selected.isEmpty {
        Text("No one selected")
          .foregroundStyle(.secondary)
      } else {
        ForEach(model.selected) { target in
          InviteIOSReviewPersonRow(target: target) {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
              model.toggle(target)
            }
          }
        }
      }
    }
  }
}

private struct InviteIOSReviewPersonRow: View {
  let target: InviteTarget
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      InviteIOSCandidateArtwork(target: target)
      InviteIOSCandidateText(target: target)
      Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
    .transition(.scale(scale: 0.92).combined(with: .opacity))
  }
}

private struct InviteIOSDestinationSection: View {
  let model: InviteComposerModel

  var body: some View {
    Section {
      NavigationLink(value: InviteIOSRoute.destination) {
        LabeledContent {
          Text(destinationTitle)
            .foregroundStyle(.secondary)
        } label: {
          Label("Invite to", systemImage: destinationSymbol)
        }
      }
    } header: {
      Text("Destination")
    } footer: {
      if model.isSpaceInvite {
        Text("Everyone selected will be invited to this space.")
      } else {
        Text("Inline starts a direct chat. Choose a space for a team or community.")
      }
    }
  }

  private var destinationTitle: String {
    model.destinationName ?? "Inline"
  }

  private var destinationSymbol: String {
    model.isSpaceInvite ? "person.3" : "message"
  }
}

private struct InviteIOSAccessSection: View {
  @Bindable var model: InviteComposerModel

  var body: some View {
    Section("Access") {
      Picker("Role", selection: $model.accessLevel) {
        ForEach(InviteComposerModel.AccessLevel.allCases) { level in
          Text(level.title).tag(level)
        }
      }
      .pickerStyle(.segmented)

      if model.accessLevel == .member {
        Toggle("Can access all public chats", isOn: $model.canAccessPublicChats)
      }
    }
  }
}

private struct InviteIOSDestinationPicker: View {
  let model: InviteComposerModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      Section {
        InviteIOSDestinationOption(
          title: "Inline",
          subtitle: "Start a direct chat",
          systemImage: "message",
          isSelected: model.destination == .inline
        ) {
          model.destination = .inline
          dismiss()
        }
      }

      if !model.spaces.isEmpty {
        Section("Spaces") {
          ForEach(model.spaces) { space in
            InviteIOSDestinationOption(
              title: space.displayName,
              subtitle: "Invite to this space",
              systemImage: "person.3",
              isSelected: model.destination == .space(id: space.id)
            ) {
              model.destination = .space(id: space.id)
              dismiss()
            }
          }
        }
      }
    }
    .navigationTitle("Invite To")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct InviteIOSDestinationOption: View {
  let title: String
  let subtitle: LocalizedStringResource
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .foregroundStyle(.primary)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isSelected {
          Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Outcome

private struct InviteIOSOutcomeScreen: View {
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  let onInviteMore: () -> Void
  let onDone: () -> Void

  var body: some View {
    List {
      InviteIOSOutcomeSection(
        title: model.isSpaceInvite ? "Added to the Space" : "Ready to Chat",
        description: model.isSpaceInvite
          ? "These people can open the space now."
          : "These people are already on Inline, so their chats are ready.",
        completions: model.peopleCompletions,
        model: model,
        onOpenChat: onOpenChat
      )
      InviteIOSOutcomeSection(
        title: "Email Sent",
        description: model.isSpaceInvite
          ? "They can join this space after accepting the email invitation."
          : "They can join Inline from the email and continue in your shared chat.",
        completions: model.emailCompletions,
        model: model,
        onOpenChat: onOpenChat
      )
      InviteIOSOutcomeSection(
        title: "Share These Invitations",
        description: "Send these people an invitation message from your preferred app.",
        completions: model.phoneCompletions,
        model: model,
        onOpenChat: onOpenChat
      )
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Invitations")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Invite More", action: onInviteMore)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Done", action: onDone)
      }
    }
  }
}

private struct InviteIOSOutcomeSection: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let completions: [InviteCompletion]
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  var body: some View {
    if !completions.isEmpty {
      Section {
        ForEach(completions) { completion in
          InviteIOSOutcomeRow(
            model: model,
            completion: completion,
            onOpenChat: onOpenChat
          )
        }
      } header: {
        Text(title)
      } footer: {
        Text(description)
      }
    }
  }
}

private struct InviteIOSOutcomeRow: View {
  let model: InviteComposerModel
  let completion: InviteCompletion
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  @Environment(\.realtimeV2) private var realtime
  @State private var isRevoking = false

  var body: some View {
    HStack(spacing: 12) {
      InviteIOSSmallArtwork(target: completion.target)
      Text(completion.target.oneLineTitle)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
      outcomeAction
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if case .space = completion.destination {
        Button("Revoke", systemImage: "person.badge.minus", role: .destructive) {
          revoke()
        }
        .disabled(isRevoking)
      }
    }
  }

  @ViewBuilder private var outcomeAction: some View {
    if case .phone = completion.target.kind {
      ShareLink(item: inviteMessage) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      .labelStyle(.iconOnly)
    } else if case .inline = completion.destination,
              case .user = completion.target.kind,
              let onOpenChat {
      Button("Open Chat") {
        onOpenChat(.user(id: completion.userID))
      }
      .buttonStyle(.borderless)
    } else if isRevoking {
      ProgressView()
        .controlSize(.small)
    } else {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
  }

  private var inviteMessage: String {
    switch completion.destination {
    case .inline:
      "Join me on Inline so we can chat: https://inline.chat/download"
    case .space:
      "Join me on Inline in \(model.name(for: completion.destination) ?? "our space"): https://inline.chat/download"
    }
  }

  private func revoke() {
    guard !isRevoking else { return }
    isRevoking = true
    Task {
      await model.revoke(completion, realtime: realtime)
      isRevoking = false
    }
  }
}
#endif
