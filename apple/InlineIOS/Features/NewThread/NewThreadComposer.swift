import Auth
import InlineKit
import InlineUI
import Logger
import SwiftUI

/// A compose box that starts a thread with its first message, the iOS counterpart of the
/// macOS new-thread composer (`AllChatsNewThreadCompose`). It hosts the iPad empty detail
/// page and the New Thread sheet.
///
/// Mentions decide who's in the thread: suggestions put the user's Agents and recent people
/// one tap away, and "@" opens the full list. The first mentioned Agent becomes the
/// thread's Agent, with its model, reasoning and folder chosen before sending.
@available(iOS 26.0, *)
struct NewThreadComposer: View {
  enum Style {
    /// A glass card pinned over content, as on the iPad empty detail page.
    case card
    /// The body of the New Thread sheet: no card chrome, focused on appear.
    case sheet
  }

  let style: Style
  let onCreated: (InlineKit.Peer) -> Void

  @StateObject private var model: NewThreadComposeModel
  @EnvironmentObject private var compactSpaceList: CompactSpaceList
  @State private var textController = NewThreadTextController()

  init(initialSpaceID: Int64?, style: Style = .card, onCreated: @escaping (InlineKit.Peer) -> Void) {
    self.style = style
    self.onCreated = onCreated
    _model = StateObject(wrappedValue: NewThreadComposeModel(
      initialSpaceID: initialSpaceID,
      realtimeV2: Api.realtime,
      currentUserID: Auth.shared.getCurrentUserId()
    ))
  }

  var body: some View {
    content
      .onAppear {
        model.start()
      }
      .onDisappear {
        model.stop()
      }
      .alert(
        model.admissionPrompt?.title ?? "",
        isPresented: Binding(
          get: { model.admissionPrompt != nil },
          set: { presented in
            if !presented, let prompt = model.admissionPrompt {
              model.answerAdmission(prompt, agreed: false)
            }
          }
        ),
        presenting: model.admissionPrompt
      ) { prompt in
        Button("Add and Send") { model.answerAdmission(prompt, agreed: true) }
        Button("Cancel", role: .cancel) { model.answerAdmission(prompt, agreed: false) }
      } message: { prompt in
        Text(prompt.message)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch style {
      case .sheet:
        sheetContent
      case .card:
        cardContent
    }
  }

  // MARK: - Layouts

  private var sheetContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        destinationRow
        editor(minHeight: 88, maxHeight: 280)
        lowerSection
      }
      .padding(.horizontal, 20)
      .padding(.top, 8)
      .padding(.bottom, 16)
    }
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      actionBar
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
  }

  private var cardContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      editor(minHeight: 36, maxHeight: 200)
      if model.mentionQuery != nil, !model.mentionItems.isEmpty {
        mentionResults(limit: 4)
      }
      HStack(spacing: 8) {
        destinationMenu
        if model.spaceID != nil { visibilityButton }
        mentionButton
        agentControls
        Spacer(minLength: 8)
        sendButton
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 14)
    .padding(.bottom, 10)
    .glassEffect(.regular, in: .rect(cornerRadius: 24))
  }

  // MARK: - Pieces

  private func editor(minHeight: CGFloat, maxHeight: CGFloat) -> some View {
    NewThreadTextView(
      controller: textController,
      initialText: model.restoredDraft,
      placeholder: String(localized: "What's this thread about? Type @ to add people or agents"),
      minHeight: minHeight,
      maxHeight: maxHeight,
      focusOnAppear: style == .sheet,
      onChange: { text, cursor in model.textDidChange(text, cursor: cursor) },
      onSubmit: submit
    )
    .disabled(model.isSending)
  }

  private var destinationRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        destinationMenu
        if model.spaceID != nil { visibilityButton }
        Spacer(minLength: 0)
      }
      Label {
        Text(model.accessSummary)
      } icon: {
        Image(systemName: model.isPublic && model.spaceID != nil ? "globe" : "lock")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .contentTransition(.opacity)
      .animation(.easeOut(duration: 0.15), value: model.accessSummary)
    }
  }

  @ViewBuilder
  private var lowerSection: some View {
    if model.mentionQuery != nil {
      if model.mentionItems.isEmpty {
        Text("No matches")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        mentionResults(limit: 8)
      }
    } else if !visibleSuggestions.isEmpty {
      suggestionsSection
    }
  }

  /// Suggestions minus whoever is already mentioned.
  private var visibleSuggestions: [MentionCompletionItem] {
    let text = model.attributedText
    var mentionedUsers = Set<Int64>()
    var mentionedAgents = Set<Int64>()
    text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
      if let id = attributes[.mentionUserId] as? Int64 { mentionedUsers.insert(id) }
      if let id = attributes[.mentionAgentId] as? Int64 { mentionedAgents.insert(id) }
    }
    return model.suggestions.filter { item in
      switch item {
        case let .agent(agent): !mentionedAgents.contains(agent.id)
        case let .user(user): !mentionedUsers.contains(user.userInfo.id)
        case .group: true
      }
    }
  }

  private var suggestionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Start with")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(visibleSuggestions) { item in
            Button {
              textController.insert(item, text: model.mentionText(for: item), replacing: nil)
            } label: {
              suggestionChip(item)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mention \(item.title)")
          }
        }
        .padding(.vertical, 2)
      }
      .scrollClipDisabled()
    }
  }

  private func suggestionChip(_ item: MentionCompletionItem) -> some View {
    HStack(spacing: 6) {
      avatar(for: item, size: 22)
      Text(chipTitle(item))
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
    }
    .padding(.leading, 5)
    .padding(.trailing, 12)
    .frame(height: 32)
    .background(Capsule().fill(Color(.secondarySystemFill)))
    .contentShape(Capsule())
  }

  private func chipTitle(_ item: MentionCompletionItem) -> String {
    switch item {
      case let .user(user):
        user.userInfo.user.bot ? user.userInfo.user.displayName
          : (user.userInfo.user.firstName ?? user.userInfo.user.displayName)
      default:
        item.title
    }
  }

  private func mentionResults(limit: Int) -> some View {
    VStack(spacing: 0) {
      ForEach(Array(model.mentionItems.prefix(limit))) { item in
        Button {
          textController.insert(item, text: model.mentionText(for: item), replacing: model.mentionQuery)
        } label: {
          HStack(spacing: 10) {
            avatar(for: item, size: 30)
            VStack(alignment: .leading, spacing: 1) {
              Text(item.title)
                .font(.body)
                .foregroundStyle(.primary)
              if let subtitle = item.subtitle {
                Text(subtitle)
                  .font(.footnote)
                  .foregroundStyle(.secondary)
              }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.vertical, 7)
          .padding(.horizontal, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
  }

  @ViewBuilder
  private func avatar(for item: MentionCompletionItem, size: CGFloat) -> some View {
    if case let .agent(agent) = item, let emoji = agent.emoji, !emoji.isEmpty {
      Text(emoji)
        .font(.system(size: size * 0.62))
        .frame(width: size, height: size)
        .background(Circle().fill(Color(.tertiarySystemFill)))
    } else if let userInfo = item.userInfo {
      UserAvatar(userInfo: userInfo, size: size)
    } else {
      Image(systemName: "person.2.fill")
        .font(.system(size: size * 0.42, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(Circle().fill(Color(.tertiarySystemFill)))
    }
  }

  // MARK: - Action bar

  private var actionBar: some View {
    HStack(spacing: 4) {
      mentionButton
      agentControls
      Spacer(minLength: 8)
      sendButton
    }
  }

  private var mentionButton: some View {
    Button {
      textController.insertMentionTrigger()
    } label: {
      Image(systemName: "at")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 36, height: 34)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.isSending)
    .accessibilityLabel("Add People or Agents")
  }

  @ViewBuilder
  private var agentControls: some View {
    if model.agentTarget != nil {
      HStack(spacing: 0) {
        if let userInfo = model.agentUserInfo {
          UserAvatar(userInfo: userInfo, size: 20)
            .padding(.horizontal, 4)
            .accessibilityLabel("Agent: \(model.agentName ?? userInfo.user.displayName)")
        }
        if model.modelTitle == nil, let name = model.agentName {
          // Until the Agent reports its models, name it so the row reads as the thread's Agent.
          Text(name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.trailing, 6)
        }
        if let title = model.projectTitle, !model.projectOptions.isEmpty {
          ComposeAgentOptionMenu(
            title: title,
            systemImage: "folder",
            automaticTitle: nil,
            options: model.projectOptions,
            selection: model.selectedProjectID,
            isDisabled: model.isSending,
            accessibilityName: "Folder",
            select: model.selectProject
          )
        }
        if let title = model.modelTitle {
          ComposeAgentOptionMenu(
            title: title,
            systemImage: nil,
            automaticTitle: model.automaticModelTitle,
            options: model.modelOptions,
            selection: model.selectedModelID,
            isDisabled: model.isSending || model.modelOptions.isEmpty,
            accessibilityName: "Model",
            select: model.selectModel
          )
        }
        if let title = model.reasoningTitle {
          ComposeAgentOptionMenu(
            title: title,
            systemImage: nil,
            automaticTitle: model.automaticReasoningTitle,
            options: model.reasoningOptions,
            selection: model.selectedReasoningID,
            isDisabled: model.isSending || model.reasoningOptions.isEmpty,
            accessibilityName: "Reasoning",
            select: model.selectReasoning
          )
        }
      }
      .lineLimit(1)
      .transition(.opacity)
    }
  }

  private var sendButton: some View {
    Button(action: submit) {
      ZStack {
        if model.isSending {
          ProgressView()
            .tint(.white)
        } else {
          Image(systemName: "arrow.up")
            .font(.system(size: 15, weight: .semibold))
        }
      }
      .frame(width: 32, height: 32)
      .foregroundStyle(.white)
      .background(Circle().fill(model.canSend || model.isSending ? Color.accentColor : Color(.systemGray3)))
    }
    .buttonStyle(.plain)
    .disabled(!model.canSend)
    .accessibilityLabel("Start Thread")
  }

  private var destinationMenu: some View {
    Menu {
      Picker("Post In", selection: Binding(get: { model.spaceID }, set: { model.selectSpace($0) })) {
        Label("Home", systemImage: "house").tag(Int64?.none)
        ForEach(compactSpaceList.spaces) { space in
          Text(space.displayName).tag(Int64?.some(space.id))
        }
      }
    } label: {
      pill(
        title: selectedSpaceName ?? String(localized: "Home"),
        systemImage: model.spaceID == nil ? "house" : "square.stack"
      )
    }
    // A menu label takes the accent tint; keep both pills the same quiet color.
    .tint(.secondary)
    .disabled(model.isSending)
    .accessibilityLabel("Post In")
    .accessibilityValue(selectedSpaceName ?? String(localized: "Home"))
  }

  private var visibilityButton: some View {
    Button {
      model.isPublic.toggle()
    } label: {
      pill(
        title: model.isPublic ? String(localized: "Public") : String(localized: "Private"),
        systemImage: model.isPublic ? "globe" : "lock"
      )
    }
    .buttonStyle(.plain)
    .disabled(model.isSending)
    .accessibilityHint(model.isPublic
      ? "Everyone in the space can find this thread."
      : "Only people you mention can see this thread.")
  }

  private func pill(title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.subheadline.weight(.medium))
      .lineLimit(1)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(Capsule().fill(Color(.tertiarySystemFill)))
  }

  private var selectedSpaceName: String? {
    guard let spaceID = model.spaceID else { return nil }
    return compactSpaceList.spaces.first { $0.id == spaceID }?.displayName
  }

  // MARK: - Submit

  private func submit() {
    guard model.canSend else { return }
    Task { @MainActor in
      if let peer = await model.submit() {
        onCreated(peer)
      }
    }
  }
}

/// New Thread on iPhone and iPad: the composer in a sheet. A created thread dismisses the
/// sheet and opens in the presenting context.
@available(iOS 26.0, *)
struct NewThreadComposerSheet: View {
  let initialSpaceID: Int64?
  let onCreated: (InlineKit.Peer) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      NewThreadComposer(initialSpaceID: initialSpaceID, style: .sheet) { peer in
        dismiss()
        onCreated(peer)
      }
      .navigationTitle("New Thread")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark", role: .cancel) {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.hidden)
  }
}

/// Identifies one New Thread sheet presentation.
struct NewThreadSheetRequest: Identifiable {
  let id = UUID()
  let spaceID: Int64?
}
