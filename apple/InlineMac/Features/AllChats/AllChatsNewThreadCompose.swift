import AppKit
import Combine
import GRDB
import InlineKit
import InlineProtocol
import InlineUI
import Logger
import SwiftUI

struct AllChatsComposeSpace: Identifiable, Equatable {
  let id: Int64
  let title: String
}

private struct AllChatsComposePreferences {
  private let defaults: UserDefaults
  private let destinationKey: String
  private let visibilityKey: String

  init(userID: Int64?, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let account = userID.map(String.init) ?? "signed-out"
    destinationKey = "macos.allChats.newThread.destination.\(account)"
    visibilityKey = "macos.allChats.newThread.public.\(account)"
  }

  var destinationSpaceID: Int64? {
    guard let value = defaults.string(forKey: destinationKey),
          value.hasPrefix("space:"),
          let id = Int64(value.dropFirst("space:".count))
    else {
      return nil
    }
    return id
  }

  var isHome: Bool {
    defaults.string(forKey: destinationKey) == "home"
  }

  var visibility: NewThreadComposeDestination.SpaceVisibility {
    defaults.bool(forKey: visibilityKey) ? .public : .private
  }

  func save(destination: NewThreadComposeDestination) {
    if let spaceID = destination.spaceID {
      defaults.set("space:\(spaceID)", forKey: destinationKey)
    } else {
      defaults.set("home", forKey: destinationKey)
    }
  }

  func save(visibility: NewThreadComposeDestination.SpaceVisibility) {
    defaults.set(visibility == .public, forKey: visibilityKey)
  }
}

private struct AllChatsComposeAccessMentions: Equatable {
  var userIDs: Set<Int64> = []
  var groupIDs: Set<Int64> = []
  var userNamesByID: [Int64: String] = [:]
  var groupNamesByID: [Int64: String] = [:]

  init(text: String = "", entities: MessageEntities? = nil) {
    let nsText = text as NSString
    for entity in entities?.entities ?? [] {
      if entity.type == .mention, entity.mention.userID > 0 {
        userIDs.insert(entity.mention.userID)
        userNamesByID[entity.mention.userID] = Self.displayName(for: entity, in: nsText)
      } else if entity.type == .groupMention, entity.groupMention.groupID > 0 {
        groupIDs.insert(entity.groupMention.groupID)
        groupNamesByID[entity.groupMention.groupID] = Self.displayName(for: entity, in: nsText)
      }
    }
  }

  private static func displayName(for entity: MessageEntity, in text: NSString) -> String? {
    guard let location = Int(exactly: entity.offset),
          let length = Int(exactly: entity.length),
          location >= 0,
          length > 0,
          location <= text.length,
          length <= text.length - location
    else {
      return nil
    }

    let entityText = text.substring(with: NSRange(location: location, length: length))
    let withoutSigil = entityText.hasPrefix("@") ? String(entityText.dropFirst()) : entityText
    let name = withoutSigil.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}

@MainActor
final class AllChatsNewThreadComposeModel: ObservableObject {
  @Published private(set) var destination: NewThreadComposeDestination
  @Published private(set) var spaces: [AllChatsComposeSpace]
  @Published private(set) var visibilityTooltipTitle = String(localized: "Private thread")
  @Published private(set) var visibilityTooltipDescription = String(
    localized: "Only you can access this thread. Mention people or groups to add them."
  )
  @Published private(set) var composeHeight: CGFloat = 42
  @Published private(set) var isSubmitting = false

  let dependencies: AppDependencies

  private let attachmentStore = NewThreadComposeAttachmentStore()
  private let log = Log.scoped("AllChatsNewThreadCompose")
  private let mentionSource: DefaultNewThreadComposeMentionSource
  private let preferences: AllChatsComposePreferences
  private var lastSpaceVisibility: NewThreadComposeDestination.SpaceVisibility
  private var accessMentions = AllChatsComposeAccessMentions()
  private var cancellables = Set<AnyCancellable>()

  init(
    dependencies: AppDependencies,
    spaces: [AllChatsComposeSpace],
    initialSpaceID: Int64?
  ) {
    self.dependencies = dependencies
    self.spaces = spaces
    let preferences = AllChatsComposePreferences(userID: dependencies.auth.currentUserId)
    self.preferences = preferences
    lastSpaceVisibility = preferences.visibility
    let persistedSpaceID = preferences.isHome ? nil : preferences.destinationSpaceID
    let restoredSpaceID = persistedSpaceID.flatMap { spaceID in
      spaces.isEmpty || spaces.contains(where: { $0.id == spaceID }) ? spaceID : nil
    }
    let initialDestination: NewThreadComposeDestination = (initialSpaceID ?? restoredSpaceID).map {
      .space(id: $0, visibility: preferences.visibility)
    } ?? .home
    destination = initialDestination
    mentionSource = DefaultNewThreadComposeMentionSource(
      db: dependencies.database,
      destination: initialDestination
    )
    mentionSource.candidateUpdates
      .sink { [weak self] _ in
        guard let self else { return }
        updateVisibilityTooltip()
      }
      .store(in: &cancellables)
  }

  var destinationTitle: String {
    guard let spaceID = destination.spaceID else { return "Home" }
    return spaces.first(where: { $0.id == spaceID })?.title ?? "Space"
  }

  var showsVisibility: Bool {
    destination.spaceID != nil
  }

  var isPublic: Bool {
    destination.isPublic
  }

  func updateSpaces(_ spaces: [AllChatsComposeSpace]) {
    self.spaces = spaces
    if let spaceID = destination.spaceID,
       !spaces.contains(where: { $0.id == spaceID })
    {
      setDestination(.home)
    } else {
      updateVisibilityTooltip()
    }
  }

  func followSelectedSpace(_ spaceID: Int64?) {
    let next: NewThreadComposeDestination = spaceID.map {
      .space(id: $0, visibility: lastSpaceVisibility)
    } ?? .home
    setDestination(next)
  }

  func selectHome() {
    setDestination(.home)
  }

  func selectSpace(_ spaceID: Int64) {
    setDestination(.space(id: spaceID, visibility: lastSpaceVisibility))
  }

  func toggleVisibility() {
    guard case let .space(id, visibility) = destination else { return }
    let next: NewThreadComposeDestination.SpaceVisibility = visibility == .private ? .public : .private
    lastSpaceVisibility = next
    preferences.save(visibility: next)
    setDestination(.space(id: id, visibility: next))
  }

  func makeContext(
    overlayHost: @escaping @MainActor () -> NSView?,
    supplementaryAccessoryView: NSView
  ) -> NewThreadComposeContext {
    NewThreadComposeContext(
      destination: { [weak self] in self?.destination ?? .home },
      mentionSource: mentionSource,
      attachmentStore: attachmentStore,
      overlayHostView: overlayHost,
      supplementaryAccessoryView: supplementaryAccessoryView,
      placeholderSymbolName: "square.and.pencil",
      didChangeDraft: { [weak self] text, entities, hasAttachments in
        self?.draftDidChange(text: text, entities: entities, hasAttachments: hasAttachments)
      },
      didChangeHeight: { [weak self] height in
        self?.composeHeight = height
      },
      didFinishSubmission: { [weak self] result in
        AllChatsNewThreadComposeModel.presentSubmissionFeedback(result)
        self?.submissionDidFinish(result)
      },
      submit: { [weak self] draft in
        guard let self else {
          return .failure(NewThreadComposeSubmissionFailure(
            message: "The new thread composer is no longer available.",
            createdPeer: nil
          ))
        }
        return await submit(draft)
      }
    )
  }

  private func setDestination(_ destination: NewThreadComposeDestination) {
    guard self.destination != destination else { return }
    self.destination = destination
    preferences.save(destination: destination)
    mentionSource.setDestination(destination)
    updateVisibilityTooltip()
    Task { await mentionSource.refresh() }
  }

  private func draftDidChange(
    text: String,
    entities: MessageEntities?,
    hasAttachments _: Bool
  ) {
    let nextMentions = AllChatsComposeAccessMentions(text: text, entities: entities)
    guard accessMentions != nextMentions else { return }
    accessMentions = nextMentions
    updateVisibilityTooltip()
  }

  private func updateVisibilityTooltip() {
    if destination.isPublic {
      visibilityTooltipTitle = String(localized: "Public thread")
      visibilityTooltipDescription = String(
        localized: "Members of \(destinationTitle) can access this thread.",
        comment: "Tooltip description for the Public visibility pill. The variable is a space name."
      )
      return
    }

    visibilityTooltipTitle = String(localized: "Private thread")

    let candidates = mentionSource.candidates
    let usersByID = Dictionary(uniqueKeysWithValues: candidates.users.map {
      ($0.userInfo.id, $0.userInfo.user.displayName)
    })
    let groupsByID = Dictionary(uniqueKeysWithValues: candidates.groups.map { ($0.id, $0.name) })
    var names = ["You"]

    for userID in accessMentions.userIDs.sorted() {
      if let name = usersByID[userID] ?? accessMentions.userNamesByID[userID] {
        names.append(name)
      }
    }
    for groupID in accessMentions.groupIDs.sorted() {
      if let name = groupsByID[groupID] ?? accessMentions.groupNamesByID[groupID] {
        names.append(name)
      }
    }
    visibilityTooltipDescription = if names.count == 1 {
      String(localized: "Only you can access this thread. Mention people or groups to add them.")
    } else {
      String(
        localized: "\(names.formatted()) can access this thread. Mention more people or groups to add them.",
        comment: "Tooltip description for the Private visibility pill. The variable is a localized list of people or groups."
      )
    }
  }

  private func submit(
    _ draft: PreparedNewThreadDraft
  ) async -> Result<InlineKit.Peer, NewThreadComposeSubmissionFailure> {
    guard !isSubmitting else {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "This thread is already being created.",
        createdPeer: nil
      ))
    }

    isSubmitting = true
    defer { isSubmitting = false }

    do {
      try await validateGroupMentions(in: draft)
    } catch NewThreadComposeSubmitError.invalidGroupMentionDestination {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "A group mention doesn't belong to the selected space. Remove it or choose its space.",
        createdPeer: nil
      ))
    } catch {
      log.error("New-thread group mention validation failed", error: error)
      return .failure(NewThreadComposeSubmissionFailure(
        message: "Couldn't verify the mentioned groups. Your message is still here.",
        createdPeer: nil
      ))
    }

    // Validate locally fixable content before reporting connectivity. Durable
    // Realtime transactions intentionally wait for a connection, but this
    // transient composer cannot turn an offline click into an indefinite
    // spinner because it has no persisted pre-chat draft after relaunch.
    guard dependencies.realtimeV2.stateObject.connectionState != .connecting else {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "You're offline. Reconnect and try again; your message is still here.",
        createdPeer: nil
      ))
    }

    var createdPeer: InlineKit.Peer?
    do {
      let participantIDs = draft.destination.isPublic
        ? []
        : Array(draft.mentionedUserIDs.union([draft.authorUserID])).sorted()
      let result = try await dependencies.realtimeV2.send(.createChat(
        title: nil,
        placeholderTitle: placeholderTitle(for: draft),
        emoji: nil,
        isPublic: draft.destination.isPublic,
        spaceId: draft.destination.spaceID,
        participants: participantIDs
      ))
      guard case let .createChat(response) = result else {
        throw NewThreadComposeSubmitError.invalidCreateResponse
      }

      let chatID = response.chat.id
      let peer: InlineKit.Peer = .thread(id: chatID)
      createdPeer = peer
      installDraft(draft, on: peer)
      openCreatedThread(peer, destination: draft.destination)

      await dependencies.realtimeV2.sendQueued(
        .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
      )

      if !draft.destination.isPublic {
        for groupID in draft.mentionedGroupIDs.sorted() {
          try await dependencies.realtimeV2.send(.addChatParticipant(
            chatID: chatID,
            groupID: groupID
          ))
        }
      }

      guard admitSend(draft, peer: peer, chatID: chatID) else {
        log.error("New-thread send transaction admission failed after thread creation")
        return .failure(NewThreadComposeSubmissionFailure(
          message: "The thread was created, but the message couldn't be queued. It was saved as a draft.",
          createdPeer: peer
        ))
      }

      Drafts2.shared.clear(peer: peer)
      Drafts2.shared.flushBlocking()
      return .success(peer)
    } catch {
      log.error("New-thread submission failed", error: error)
      return .failure(NewThreadComposeSubmissionFailure(
        message: createdPeer == nil
          ? "Failed to create thread. Your message is still here."
          : "The thread was created, but the message couldn't be sent. It was saved as a draft.",
        createdPeer: createdPeer
      ))
    }
  }

  private func validateGroupMentions(in draft: PreparedNewThreadDraft) async throws {
    guard !draft.mentionedGroupIDs.isEmpty else { return }
    guard let spaceID = draft.destination.spaceID else {
      throw NewThreadComposeSubmitError.invalidGroupMentionDestination
    }

    let groupIDs = draft.mentionedGroupIDs
    let validCount = try await dependencies.database.reader.read { db in
      try UserGroup
        .filter(groupIDs.contains(UserGroup.Columns.id))
        .filter(UserGroup.Columns.spaceId == spaceID)
        .fetchCount(db)
    }
    guard validCount == groupIDs.count else {
      throw NewThreadComposeSubmitError.invalidGroupMentionDestination
    }
  }

  private func placeholderTitle(for draft: PreparedNewThreadDraft) -> String {
    let normalized = draft.text
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
    guard !normalized.isEmpty else { return "Message" }
    return String(normalized.prefix(60))
  }

  private func installDraft(_ draft: PreparedNewThreadDraft, on peer: InlineKit.Peer) {
    let revision = Drafts2.shared.updateText(peer: peer, text: draft.text)
    _ = Drafts2.shared.updateEntities(peer: peer, entities: draft.entities, forRevision: revision)
    for attachment in draft.attachments {
      Drafts2.shared.appendAttachment(peer: peer, media: attachment.media, id: attachment.id)
    }
    Drafts2.shared.flushBlocking()
  }

  private func openCreatedThread(
    _ peer: InlineKit.Peer,
    destination: NewThreadComposeDestination
  ) {
    guard let spaceID = destination.spaceID else {
      dependencies.requestOpenChatInHome(peer: peer)
      return
    }

    let spaceName = spaces.first(where: { $0.id == spaceID })?.title ?? "Space"
    if dependencies.nav2 != nil {
      dependencies.openSpaceContext(id: spaceID, name: spaceName, keeping: peer)
    } else if let nav3 = dependencies.nav3 {
      nav3.selectSpace(spaceID)
      dependencies.requestOpenChat(peer: peer)
    } else {
      dependencies.openSpaceContext(id: spaceID, name: spaceName, keeping: peer)
    }
  }

  private func admitSend(_ draft: PreparedNewThreadDraft, peer: InlineKit.Peer, chatID: Int64) -> Bool {
    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil
      : draft.text
    if draft.attachments.isEmpty {
      return dependencies.transactions.mutate(transaction: .sendMessage(
        TransactionSendMessage(
          text: text,
          peerId: peer,
          chatId: chatID,
          entities: draft.entities
        )
      ))
    }

    for (index, attachment) in draft.attachments.enumerated() {
      let admitted = dependencies.transactions.mutate(transaction: .sendMessage(
        TransactionSendMessage(
          text: index == 0 ? text : nil,
          peerId: peer,
          chatId: chatID,
          mediaItems: [attachment.media],
          entities: index == 0 ? draft.entities : nil
        )
      ))
      guard admitted else {
        Drafts2.shared.flushBlocking()
        return false
      }

      // Once a transaction is durably admitted it owns this portion of the
      // content. Remove only that portion from recovery so a later admission
      // failure cannot make the fallback draft duplicate already-queued work.
      Drafts2.shared.removeAttachment(peer: peer, id: attachment.id)
      if index == 0 {
        let revision = Drafts2.shared.updateText(peer: peer, text: "")
        _ = Drafts2.shared.updateEntities(peer: peer, entities: nil, forRevision: revision)
      }
      Drafts2.shared.flushBlocking()
    }
    return true
  }

  private func submissionDidFinish(
    _ result: Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>
  ) {
    switch result {
      case .success:
        accessMentions = AllChatsComposeAccessMentions()
        updateVisibilityTooltip()
      case let .failure(failure):
        if failure.createdPeer != nil {
          accessMentions = AllChatsComposeAccessMentions()
          updateVisibilityTooltip()
        }
    }
  }

  private static func presentSubmissionFeedback(
    _ result: Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>
  ) {
    if case let .failure(failure) = result {
      ToastCenter.shared.showError(failure.message)
    }
  }
}

private enum NewThreadComposeSubmitError: Error {
  case invalidCreateResponse
  case invalidGroupMentionDestination
}

private final class WeakNewThreadComposeHost {
  weak var view: NSView?
}

private final class NewThreadComposeOverlayHostView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    for subview in subviews.reversed() where !subview.isHidden {
      let convertedPoint = convert(point, to: subview)
      if let hitView = subview.hitTest(convertedPoint) {
        return hitView
      }
    }
    return nil
  }
}

@available(macOS 26.0, *)
private final class NewThreadGlassComposeHostView: NSView {
  let compose: GlassComposeAppKit
  private weak var completionOverlayHostView: NewThreadComposeOverlayHostView?

  init(model: AllChatsNewThreadComposeModel) {
    let weakHost = WeakNewThreadComposeHost()
    let supplementaryAccessoryView = NSHostingView(
      rootView: AllChatsComposeAccessoryView(model: model)
    )
    compose = GlassComposeAppKit(
      newThread: model.makeContext(
        overlayHost: {
          (weakHost.view as? NewThreadGlassComposeHostView)?.completionOverlayHost()
        },
        supplementaryAccessoryView: supplementaryAccessoryView
      ),
      dependencies: model.dependencies,
      layout: .accessoryBar,
      capabilities: .allChatsNewThread
    )
    super.init(frame: .zero)
    weakHost.view = self

    translatesAutoresizingMaskIntoConstraints = false
    compose.translatesAutoresizingMaskIntoConstraints = false
    addSubview(compose)
    NSLayoutConstraint.activate([
      compose.leadingAnchor.constraint(equalTo: leadingAnchor),
      compose.trailingAnchor.constraint(equalTo: trailingAnchor),
      compose.topAnchor.constraint(equalTo: topAnchor),
      compose.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    compose.didLayout()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      completionOverlayHostView?.removeFromSuperview()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  private func completionOverlayHost() -> NSView? {
    if let completionOverlayHostView,
       completionOverlayHostView.superview != nil
    {
      return completionOverlayHostView
    }

    guard let contentView = window?.contentView,
          let frameView = contentView.superview
    else {
      return nil
    }

    let overlayView = NewThreadComposeOverlayHostView()
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    frameView.addSubview(overlayView, positioned: .above, relativeTo: contentView)
    NSLayoutConstraint.activate([
      overlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    // Completion constraints use coordinates local to this overlay immediately
    // after it is created. Resolve its content-view constraints before handing
    // it to Compose so the first menu frame is not calculated from `.zero`.
    frameView.layoutSubtreeIfNeeded()
    completionOverlayHostView = overlayView
    return overlayView
  }
}

@available(macOS 26.0, *)
private struct NewThreadGlassComposeRepresentable: NSViewRepresentable {
  @ObservedObject var model: AllChatsNewThreadComposeModel

  func makeNSView(context: Context) -> NewThreadGlassComposeHostView {
    NewThreadGlassComposeHostView(model: model)
  }

  func updateNSView(_ nsView: NewThreadGlassComposeHostView, context: Context) {}
}

@available(macOS 26.0, *)
struct AllChatsNewThreadComposeHost: View {
  @StateObject private var model: AllChatsNewThreadComposeModel

  let spaces: [AllChatsComposeSpace]
  let selectedSpaceID: Int64?

  init(
    dependencies: AppDependencies,
    spaces: [AllChatsComposeSpace],
    selectedSpaceID: Int64?
  ) {
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
    _model = StateObject(wrappedValue: AllChatsNewThreadComposeModel(
      dependencies: dependencies,
      spaces: spaces,
      initialSpaceID: selectedSpaceID
    ))
  }

  var body: some View {
    NewThreadGlassComposeRepresentable(model: model)
      .frame(maxWidth: .infinity)
      .frame(height: model.composeHeight)
      .padding(.horizontal, 12)
      .zIndex(10)
      .onChange(of: spaces) { _, value in
        model.updateSpaces(value)
      }
      .onChange(of: selectedSpaceID) { _, value in
        model.followSelectedSpace(value)
      }
  }
}

@available(macOS 26.0, *)
private struct AllChatsComposeAccessoryView: View {
  @ObservedObject var model: AllChatsNewThreadComposeModel

  var body: some View {
    HStack(spacing: 4) {
      Menu {
        Button("Home", action: model.selectHome)
        if !model.spaces.isEmpty {
          Divider()
        }
        ForEach(model.spaces) { space in
          Button(space.title) {
            model.selectSpace(space.id)
          }
        }
      } label: {
        AllChatsComposePillLabel(title: model.destinationTitle)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize(horizontal: true, vertical: true)
      .disabled(model.isSubmitting)

      if model.showsVisibility {
        Button(action: model.toggleVisibility) {
          AllChatsComposePillLabel(title: model.isPublic ? "Public" : "Private")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .disabled(model.isSubmitting)
        .inlineTooltip(
          verbatim: model.visibilityTooltipTitle,
          description: model.visibilityTooltipDescription
        )
        .transition(.opacity)
      }

      Spacer(minLength: 0)

      if model.isSubmitting {
        ProgressView()
          .controlSize(.mini)
      }
    }
    .frame(height: 24)
    .animation(.easeOut(duration: 0.16), value: model.showsVisibility)
  }

}

@available(macOS 26.0, *)
private struct AllChatsComposePillLabel: View {
  let title: String
  @State private var isHovering = false

  var body: some View {
    Text(title)
      .font(.system(size: 11.5, weight: .medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: 144, alignment: .leading)
      .padding(.horizontal, 8)
      .frame(height: 24)
      .background {
        Capsule()
          .fill(.quaternary)
          .opacity(isHovering ? 1 : 0)
      }
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }
}
