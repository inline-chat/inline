import InlineCompatUI
import InlineIOSFoundation
import InlineKit
import InlineUI
import Invite
import SwiftUI
import UIKit

/// Destination and sheet → controller. UIKit screens are used on every system; screens not
/// ported yet use the SwiftUI bridge on iOS 17+ and a UIKit stand-in before.
extension MainShellController {
  func makeController(for destination: Destination) -> UIViewController {
    switch destination {
    case .chats:
      return HomeListViewController(shell: self, surface: .inbox)
    case .archived:
      return HomeListViewController(shell: self, surface: .archived)
    case let .space(id):
      // Legacy route: spaces are a home scope now. Switch to it and drop the route.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        home.activeSpaceId = id
        let tab = router.selectedTab
        router.setPathFromNavigation(router[tab].filter { $0.legacySpaceID == nil }, for: tab)
      }
      return UIViewController()
    case let .chat(peer):
      return ChatViewController(peer: peer, shell: self, options: .init(
        contextSpaceID: home.activeSpaceId,
        autoCleanupUntitledEmptyThreadOnBack: true
      ))
    case let .externalChat(peer, contextSpaceID, messageID):
      if home.activeSpaceId != contextSpaceID { home.activeSpaceId = nil }
      return ChatViewController(peer: peer, shell: self, options: .init(
        contextSpaceID: contextSpaceID,
        focusMessageID: messageID,
        autoCleanupUntitledEmptyThreadOnBack: true
      ))
    case let .chatMessage(peer, messageID), let .voiceMessage(peer, messageID):
      return ChatViewController(peer: peer, shell: self, options: .init(
        contextSpaceID: home.activeSpaceId,
        focusMessageID: messageID,
        focusMessageExactly: destination.requiresExactMessageFocus,
        autoCleanupUntitledEmptyThreadOnBack: true
      ))
    case .spaces:
      // Legacy route: spaces are a home scope now.
      return HomeListViewController(shell: self, surface: .allChats)
    case .chatInfo, .grid, .spaceSettings, .spaceIntegrations, .integrationOptions,
         .createSpaceChat, .createThread, .createSpace:
      if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
        return bridgedController(for: destination)
      }
      return UnavailableFeatureViewController(title: Self.fallbackTitle(for: destination))
    }
  }

  func makeSheetController(for sheet: Sheet) -> UIViewController {
    let controller: UIViewController
    if case .settings = sheet, !Self.prefersBridgedSettings {
      let navigation = SheetNavigationController(root: SettingsViewController(shell: self), showsCancel: false)
      navigation.modalPresentationStyle = .pageSheet
      controller = navigation
    } else if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      controller = bridgedSheet(for: sheet)
    } else {
      controller = Self.unavailableSheet(title: Self.fallbackTitle(for: sheet))
    }
    sheetDismissalRelay.shell = self
    controller.presentationController?.delegate = sheetDismissalRelay
    return controller
  }

  // MARK: Presentations owned by a chat

  func presentChatInfo(_ item: SpaceChatItem, from presenter: UIViewController, editing: Bool) {
    let controller: UIViewController
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      controller = SwiftUIBridge.sheet(
        NavigationStack { ChatInfoView(chatItem: item, isPresentedModally: true, initiallyEditingInfo: editing) },
        shell: self
      )
    } else {
      controller = Self.unavailableSheet(title: String(localized: "Chat Info"))
    }
    presenter.topmostPresented.present(controller, animated: true)
  }

  func presentUserGroupMembers(_ target: UserGroupMentionTarget, from presenter: UIViewController) {
    let controller: UIViewController
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      controller = SwiftUIBridge.sheet(UserGroupMembersSheet(target: target), shell: self, detents: [.medium, .large])
    } else {
      controller = Self.unavailableSheet(title: String(localized: "Group"))
    }
    presenter.topmostPresented.present(controller, animated: true)
  }

  func presentBotAgentProfile(_ target: BotAgentMentionTarget, from presenter: UIViewController) {
    let controller: UIViewController
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) {
      controller = SwiftUIBridge.sheet(BotAgentProfileSheet(target: target), shell: self, detents: [.medium, .large])
    } else {
      controller = Self.unavailableSheet(title: String(localized: "Agent"))
    }
    presenter.topmostPresented.present(controller, animated: true)
  }

  /// The SwiftUI Settings covers more pages; keep it on iOS 17+ until the UIKit one catches up.
  private static var prefersBridgedSettings: Bool {
    if #available(iOS 18.0, *), CompatRuntime.allows(.iOS18) { return true }
    return false
  }

  // MARK: Fallbacks

  private static func unavailableSheet(title: String) -> UIViewController {
    let navigation = SheetNavigationController(root: UnavailableFeatureViewController(title: title))
    navigation.modalPresentationStyle = .pageSheet
    return navigation
  }

  static func fallbackTitle(for destination: Destination) -> String {
    switch destination {
    case .spaces: String(localized: "Spaces")
    case .chatInfo: String(localized: "Chat Info")
    case .grid: String(localized: "Grid")
    case .spaceSettings: String(localized: "Space Settings")
    case .spaceIntegrations, .integrationOptions: String(localized: "Integrations")
    case .createSpaceChat, .createThread: String(localized: "New Thread")
    case .createSpace: String(localized: "Create Space")
    default: ""
    }
  }

  static func fallbackTitle(for sheet: Sheet) -> String {
    switch sheet {
    case .settings: String(localized: "Settings")
    case .connectors: String(localized: "Integrations")
    case .createSpace: String(localized: "Create Space")
    case .addMember, .inviteToInline: String(localized: "Invite")
    case .members: String(localized: "Members")
    case .chatInfo: String(localized: "Chat Info")
    case .whatsNew: String(localized: "What's New")
    }
  }
}

// MARK: - iOS 17+ bridged screens

@available(iOS 18.0, *)
extension MainShellController {
  fileprivate func bridgedController(for destination: Destination) -> UIViewController {
    let title = Self.fallbackTitle(for: destination)
    switch destination {
    case let .chatInfo(chatItem):
      return SwiftUIBridge.controller(ChatInfoView(chatItem: chatItem), shell: self, title: title)
    case let .grid(initialSpaceID):
      return SwiftUIBridge.controller(GridDestinationView(initialSpaceID: initialSpaceID), shell: self, title: title)
    case let .spaceSettings(spaceId):
      return SwiftUIBridge.controller(SpaceSettingsView(spaceId: spaceId, usesRouterNavigation: true), shell: self, title: title)
    case let .spaceIntegrations(spaceId):
      return SwiftUIBridge.controller(SpaceIntegrationsView(spaceId: spaceId), shell: self, title: title)
    case let .integrationOptions(spaceId, provider):
      return SwiftUIBridge.controller(IntegrationOptionsView(spaceId: spaceId, provider: provider), shell: self, title: title)
    case .createSpaceChat:
      return SwiftUIBridge.controller(CreateChatView(spaceId: nil), shell: self, title: title)
    case let .createThread(spaceId):
      return SwiftUIBridge.controller(CreateChatView(spaceId: spaceId), shell: self, title: title)
    case .createSpace:
      return SwiftUIBridge.controller(
        CreateSpaceView(onCreated: { [weak self] id in self?.selectSpace(id) }), shell: self, title: title
      )
    default:
      return UnavailableFeatureViewController(title: title)
    }
  }

  fileprivate func bridgedSheet(for sheet: Sheet) -> UIViewController {
    switch sheet {
    case .settings:
      return SwiftUIBridge.sheet(
        NavigationStack { SettingsView(onSelectSpace: { [weak self] id in self?.selectSpace(id) }) },
        shell: self
      )
    case let .connectors(callbackURL):
      return SwiftUIBridge.sheet(
        NavigationStack { ConnectorsView(initialOAuthCallbackURL: URL(string: callbackURL)) }, shell: self
      )
    case .createSpace:
      return SwiftUIBridge.sheet(
        CreateSpace(onCreated: { [weak self] id in self?.selectSpace(id) }), shell: self, detents: [.medium, .large]
      )
    case let .addMember(spaceId):
      return SwiftUIBridge.sheet(
        InviteView(destination: .space(id: spaceId), onCreateSpace: { [weak self] in self?.router.presentSheet(.createSpace) }),
        shell: self
      )
    case .inviteToInline:
      return SwiftUIBridge.sheet(
        InviteView(
          destination: .inline,
          onOpenChat: { [weak self] peer in
            self?.router.dismissSheet()
            self?.router.openPrimaryDestination(.chat(peer: peer))
          },
          onCreateSpace: { [weak self] in self?.router.presentSheet(.createSpace) }
        ),
        shell: self
      )
    case let .members(spaceId):
      return SwiftUIBridge.sheet(ExperimentalMembersSheetView(spaceId: spaceId), shell: self)
    case let .chatInfo(chatItem):
      return SwiftUIBridge.sheet(NavigationStack { ChatInfoView(chatItem: chatItem) }, shell: self, detents: [.medium, .large])
    case .whatsNew:
      guard let announcement = WhatsNewStore.shared.announcement else {
        return UnavailableFeatureViewController(title: Self.fallbackTitle(for: sheet))
      }
      return SwiftUIBridge.sheet(
        WhatsNewView(announcement: announcement, onContinue: { [weak self] in self?.router.dismissSheet() }),
        shell: self
      )
    }
  }
}

/// Clears `router.presentedSheet` when the person swipes a router-driven sheet away.
@MainActor
final class SheetDismissalRelay: NSObject, UIAdaptivePresentationControllerDelegate {
  weak var shell: MainShellController?

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    shell?.sheetDidDismiss(presentationController.presentedViewController)
  }
}
