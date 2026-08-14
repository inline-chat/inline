#if os(macOS)
import AppKit
import InlineKit
import InlineUI
import RealtimeV2
import SwiftUI

struct InviteMacView: View {
  @Bindable var model: InviteComposerModel
  @Environment(\.realtimeV2) private var realtime
  @State private var localStage: InviteFlowStage = .selection

  let stage: InviteFlowStage?
  let onContinue: (() -> Void)?
  let onShowOutcome: (() -> Void)?
  let onInviteMore: (() -> Void)?
  let onManageMembers: ((Int64) -> Void)?
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  var body: some View {
    Group {
      switch stage ?? localStage {
      case .selection:
        InviteMacSelectionScreen(model: model) {
          if let onContinue {
            onContinue()
          } else {
            show(.review)
          }
        }
      case .review:
        InviteMacOptionsScreen(
          model: model,
          onInvite: invite
        )
      case .outcome:
        InviteMacOutcomeScreen(
          model: model,
          onOpenChat: onOpenChat,
          onManageMembers: onManageMembers,
          onInviteMore: {
            model.returnToInvite()
            if let onInviteMore {
              onInviteMore()
            } else {
              show(.selection)
            }
          }
        )
      }
    }
    .animation(.easeInOut(duration: 0.16), value: localStage)
  }

  private func show(_ nextStage: InviteFlowStage) {
    withAnimation(.easeInOut(duration: 0.16)) {
      localStage = nextStage
    }
  }

  private func invite() {
    Task {
      if await model.invite(realtime: realtime) {
        if let onShowOutcome {
          onShowOutcome()
        } else {
          show(.outcome)
        }
      }
    }
  }
}

private struct InviteMacSelectionScreen: View {
  @Bindable var model: InviteComposerModel
  @State private var isSearchFocused = true
  let onNext: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      InviteMacSearchSurface(
        text: $model.query,
        isFocused: $isSearchFocused,
        onContacts: model.showContacts
      )
      .frame(maxWidth: 680)
      .padding(.horizontal, 20)

      if !model.selected.isEmpty {
        InviteMacSelectionTokens(targets: model.selected, onRemove: model.toggle)
          .frame(maxWidth: 680, alignment: .leading)
          .padding(.horizontal, 20)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if model.hasSuggestions {
        Form {
          InviteMacSuggestionSection(title: "Invite Users", targets: model.userTargets, model: model)
          InviteMacSuggestionSection(title: "Contacts", targets: model.contactTargets, model: model)
          InviteMacSuggestionSection(
            title: "Send Email Invite",
            targets: model.emailSuggestion.map { [$0] } ?? [],
            model: model
          )
          InviteMacSuggestionSection(
            title: "Invite Phone Number",
            targets: model.phoneTarget.map { [$0] } ?? [],
            model: model
          )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      } else {
        InviteMacSelectionStatus(
          queryIsEmpty: model.normalizedQuery.isEmpty,
          isSearching: model.isSearching,
          message: model.emptyResultMessage,
          emptyDescription: model.fixesDestination
            ? "Search Inline or invite someone by email or phone."
            : "Search Inline or invite someone by email or phone. You can choose where they join next."
        )
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(.top, 18)
    .navigationTitle("Invite")
    .toolbar(removing: .title)
    .toolbar {
      let titleItem = ToolbarItem(placement: .navigation) {
        InviteMacToolbarTitle(title: "Invite", subtitle: selectionSubtitle)
      }
      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
      } else {
        titleItem
      }

      ToolbarItem(placement: .primaryAction) {
        Button("Continue", systemImage: "arrow.right", action: onNext)
          .labelStyle(.iconOnly)
          .disabled(model.selected.isEmpty)
          .help("Continue")
      }
    }
    .onAppear {
      isSearchFocused = true
    }
  }

  private var selectionSubtitle: String {
    if model.selected.isEmpty {
      return model.isSpaceInvite ? model.destinationName ?? "Space" : "Inline"
    }
    return model.selected.count == 1 ? "1 selected" : "\(model.selected.count) selected"
  }
}

private struct InviteMacSearchSurface: View {
  @Binding var text: String
  @Binding var isFocused: Bool
  let onContacts: () -> Void

  var body: some View {
    let field = HStack(spacing: 9) {
      Image(systemName: "magnifyingglass")
        .font(.body)
        .foregroundStyle(.secondary)

      InviteMacAppKitSearchField(
        text: $text,
        isFocused: $isFocused,
        placeholder: "Username, email, or phone"
      )
      .frame(height: 28)

      if !text.isEmpty {
        Button("Clear Search", systemImage: "xmark.circle.fill") {
          text = ""
          isFocused = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .transition(.scale.combined(with: .opacity))
      }

      Button("Find from Contacts", systemImage: "person.crop.circle.badge.plus", action: onContacts)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Find from Contacts")
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
    .contentShape(.capsule)
    .onTapGesture {
      isFocused = true
    }

    if #available(macOS 26.0, *) {
      field.glassEffect(.regular.interactive(), in: .capsule)
    } else {
      field
        .background(.regularMaterial, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        }
    }
  }
}

private struct InviteMacSelectionTokens: View {
  let targets: [InviteTarget]
  let onRemove: (InviteTarget) -> Void

  @ViewBuilder
  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(targets) { target in
          tokenButton(target)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.vertical, 8)
    }
    .scrollIndicators(.hidden)
    .animation(.snappy, value: targets.map(\.id))
  }

  @ViewBuilder
  private func tokenButton(_ target: InviteTarget) -> some View {
    let button = Button {
      withAnimation(.snappy) {
        onRemove(target)
      }
    } label: {
      HStack(spacing: 6) {
        InviteMacTargetArtwork(target: target, size: 20)
        Text(target.title)
          .lineLimit(1)
        Image(systemName: "xmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 3)
    }
    .buttonBorderShape(.capsule)
    .controlSize(.small)
    .accessibilityLabel("Remove \(target.title) from invitation")

    if #available(macOS 26.0, *) {
      button
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    } else {
      button
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary, in: .capsule)
    }
  }
}

private struct InviteMacSuggestionSection: View {
  let title: LocalizedStringResource
  let targets: [InviteTarget]
  let model: InviteComposerModel

  var body: some View {
    if !targets.isEmpty {
      Section {
        ForEach(targets) { target in
          InviteMacCandidateRow(
            target: target,
            isSelected: model.isSelected(target)
          ) {
            withAnimation(.snappy) {
              model.selectFromResults(target)
            }
          }
        }
      } header: {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textCase(nil)
      }
    }
  }
}

private struct InviteMacCandidateRow: View {
  let target: InviteTarget
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        InviteMacTargetArtwork(target: target, size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text(target.title)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let detail = target.detail {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.body)
            .symbolEffect(.bounce, value: isSelected)
            .foregroundStyle(.tint)
            .transition(.scale.combined(with: .opacity))
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!target.isActionable)
    .opacity(target.isActionable ? 1 : 0.55)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct InviteMacTargetArtwork: View {
  let target: InviteTarget
  let size: CGFloat

  var body: some View {
    HStack {
      switch target.kind {
      case let .user(info):
        UserAvatar(userInfo: info, size: size)
      case .email, .phone:
        Image(systemName: target.symbol)
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
      }
    }
  }
}

private struct InviteMacSelectionStatus: View {
  let queryIsEmpty: Bool
  let isSearching: Bool
  let message: LocalizedStringResource?
  let emptyDescription: LocalizedStringResource

  var body: some View {
    if isSearching {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Searching…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 64)
    } else if let message {
      VStack(spacing: 5) {
        Text("No Results")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 420)
      .frame(maxWidth: .infinity, minHeight: 80)
    } else if queryIsEmpty {
      VStack(spacing: 6) {
        Image(systemName: "person.badge.plus")
          .font(.title3)
          .foregroundStyle(.tertiary)
        Text("Find people to invite")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.secondary)
        Text(emptyDescription)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
      .frame(maxWidth: 420)
      .frame(maxWidth: .infinity, minHeight: 112)
    }
  }
}

private struct InviteMacOptionsScreen: View {
  @Bindable var model: InviteComposerModel
  let onInvite: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if !model.fixesDestination {
          Section {
            Picker("Invite to", selection: $model.destination) {
              Text("Inline — Start a Chat")
                .tag(InviteDestination.inline)

              if !model.spaces.isEmpty {
                Divider()
                Section("Spaces") {
                  ForEach(model.spaces) { space in
                    Text(space.displayName)
                      .tag(InviteDestination.space(id: space.id))
                  }
                }
              }
            }
            .pickerStyle(.menu)
          } header: {
            Text("Destination")
          } footer: {
            Text(destinationHelp)
          }
        }

        if model.isSpaceInvite {
          Section("Access") {
            LabeledContent("Role") {
              Picker("Role", selection: $model.accessLevel) {
                ForEach(InviteComposerModel.AccessLevel.allCases) { level in
                  Text(level.title).tag(level)
                }
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .frame(width: 180)
            }

            if model.accessLevel == .member {
              Toggle("Can access all public chats", isOn: $model.canAccessPublicChats)
            }
          }
        }

        Section("Inviting") {
          ForEach(model.selected) { target in
            InviteMacReviewPersonRow(
              target: target,
              actionDescription: actionDescription(for: target)
            ) {
              withAnimation(.snappy) {
                model.toggle(target)
              }
            }
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Invite")
    .toolbar(removing: .title)
    .toolbar {
      let titleItem = ToolbarItem(placement: .navigation) {
        InviteMacToolbarTitle(
          title: "Invite",
          subtitle: reviewSubtitle
        )
      }
      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
      } else {
        titleItem
      }

      ToolbarItem(placement: .primaryAction) {
        Button(
          "Send Invitations",
          systemImage: model.isSending ? "clock" : "checkmark",
          action: onInvite
        )
        .labelStyle(.iconOnly)
        .disabled(model.selected.isEmpty || model.isSending)
        .help("Send Invitations")
      }
    }
  }

  private var destinationHelp: LocalizedStringResource {
    switch model.destination {
    case .inline:
      "Invite to Inline to start a direct chat. Choose a space for a team or community."
    case .space:
      "Everyone selected will be invited to this space."
    }
  }

  private var reviewSubtitle: String {
    let count = model.selected.count == 1 ? "1 person" : "\(model.selected.count) people"
    guard model.fixesDestination, let destinationName = model.destinationName else { return count }
    return "\(destinationName) · \(count)"
  }

  private func actionDescription(for target: InviteTarget) -> String {
    switch (target.kind, model.destination) {
    case (.user, .inline):
      "Start a chat on Inline"
    case (.email, .inline):
      "Send an email invitation to join Inline"
    case (.phone, .inline):
      "Share an Inline invitation by text message"
    case (.user, .space):
      "Add to \(model.destinationName ?? "the space") as \(model.accessLevel == .admin ? "an admin" : "a member")"
    case (.email, .space):
      "Send an email invitation to join \(model.destinationName ?? "the space")"
    case (.phone, .space):
      "Share an invitation to join \(model.destinationName ?? "the space") by text message"
    }
  }
}

private struct InviteMacReviewPersonRow: View {
  let target: InviteTarget
  let actionDescription: String
  let onRemove: () -> Void
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 10) {
      InviteMacTargetArtwork(target: target, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(target.oneLineTitle)
          .lineLimit(1)
        Text(actionDescription)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
    .onHover { isHovering = $0 }
  }
}

private struct InviteMacOutcomeScreen: View {
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  let onManageMembers: ((Int64) -> Void)?
  let onInviteMore: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Form {
        InviteMacOutcomeSection(
          title: model.isSpaceInvite ? "Added to the Space" : "Ready to Chat",
          description: model.isSpaceInvite
            ? "These people can open the space now."
            : "These people are already on Inline, so their chat is ready.",
          completions: model.peopleCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
        InviteMacOutcomeSection(
          title: "Email Sent",
          description: model.isSpaceInvite
            ? "They’ll join this space after accepting and signing in."
            : "They can join Inline from the email and continue in your shared chat.",
          completions: model.emailCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
        InviteMacOutcomeSection(
          title: "Share These Invitations",
          description: "Send each person an invite message so they can join Inline.",
          completions: model.phoneCompletions,
          model: model,
          onOpenChat: onOpenChat
        )
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle("Invitations")
    .toolbar(removing: .title)
    .toolbar {
      let titleItem = ToolbarItem(placement: .navigation) {
        InviteMacToolbarTitle(title: "Invitations", subtitle: "Review what happened")
      }
      if #available(macOS 26.0, *) {
        titleItem.sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
      } else {
        titleItem
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Button("Invite More", systemImage: "plus", action: onInviteMore)
          .labelStyle(.iconOnly)
          .help("Invite More")
        if case let .space(spaceID) = model.destination, let onManageMembers {
          Button("Manage Members", systemImage: "person.3") {
            onManageMembers(spaceID)
          }
          .labelStyle(.iconOnly)
          .help("Manage Members")
        }
      }
    }
  }
}

private struct InviteMacOutcomeSection: View {
  let title: LocalizedStringResource
  let description: LocalizedStringResource
  let completions: [InviteCompletion]
  let model: InviteComposerModel
  let onOpenChat: ((InlineKit.Peer) -> Void)?

  var body: some View {
    if !completions.isEmpty {
      Section {
        ForEach(completions) { completion in
          InviteMacOutcomeRow(model: model, completion: completion, onOpenChat: onOpenChat)
        }
      } header: {
        Text(title)
      } footer: {
        Text(description)
      }
    }
  }
}

private struct InviteMacOutcomeRow: View {
  let model: InviteComposerModel
  let completion: InviteCompletion
  let onOpenChat: ((InlineKit.Peer) -> Void)?
  @Environment(\.realtimeV2) private var realtime
  @State private var isHoveringRevoke = false

  var body: some View {
    HStack(spacing: 10) {
      InviteMacTargetArtwork(target: completion.target, size: 28)
      VStack(alignment: .leading, spacing: 1) {
        Text(completion.target.title).lineLimit(1)
        if let detail = completion.target.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if case .phone = completion.target.kind {
        ShareLink(item: inviteMessage) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      } else if case .inline = completion.destination,
                case .user = completion.target.kind,
                let onOpenChat {
        Button("Open Chat") {
          onOpenChat(.user(id: completion.userID))
        }
      }

      if case .space = completion.destination {
        Button {
          Task { await model.revoke(completion, realtime: realtime) }
        } label: {
          Image(systemName: isHoveringRevoke ? "xmark.circle.fill" : "checkmark.circle.fill")
            .foregroundStyle(isHoveringRevoke ? .red : .green)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringRevoke = $0 }
        .accessibilityLabel("Revoke invitation for \(completion.target.title)")
      } else if case .phone = completion.target.kind {
        EmptyView()
      } else if case .user = completion.target.kind, onOpenChat != nil {
        EmptyView()
      } else {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
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
}

private struct InviteMacToolbarTitle: View {
  let title: LocalizedStringResource
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .lineLimit(1)
      Text(subtitle)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .fixedSize(horizontal: true, vertical: true)
  }
}

private struct InviteMacAppKitSearchField: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  let placeholder: String

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> InviteMacSearchTextField {
    let searchField = InviteMacSearchTextField()
    searchField.delegate = context.coordinator
    searchField.placeholderString = placeholder
    searchField.target = context.coordinator
    searchField.action = #selector(Coordinator.submit)
    return searchField
  }

  func updateNSView(_ searchField: InviteMacSearchTextField, context: Context) {
    if searchField.stringValue != text {
      searchField.stringValue = text
    }
    if searchField.placeholderString != placeholder {
      searchField.placeholderString = placeholder
    }

    guard isFocused,
          let window = searchField.window,
          window.firstResponder !== searchField.currentEditor()
    else { return }

    DispatchQueue.main.async { [weak searchField] in
      guard let searchField, searchField.window === window else { return }
      window.makeFirstResponder(searchField)
    }
  }

  static func dismantleNSView(_ searchField: InviteMacSearchTextField, coordinator: Coordinator) {
    searchField.delegate = nil
    searchField.target = nil
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    @Binding private var text: String
    @Binding private var isFocused: Bool

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
      isFocused = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      isFocused = false
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let searchField = notification.object as? NSTextField,
            text != searchField.stringValue
      else { return }
      text = searchField.stringValue
    }

    @objc func submit() {}
  }
}

private final class InviteMacSearchTextField: NSTextField {
  init() {
    super.init(frame: .zero)
    isBezeled = false
    isBordered = false
    drawsBackground = false
    focusRingType = .none
    font = .systemFont(ofSize: NSFont.systemFontSize)
    isEditable = true
    isSelectable = true
    cell?.usesSingleLineMode = true
    cell?.lineBreakMode = .byTruncatingTail
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
#endif
