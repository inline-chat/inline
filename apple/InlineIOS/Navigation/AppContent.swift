import InlineKit
import SwiftUI

typealias Router = NavigationModel<AppTab, Destination, Sheet>

enum AppTab: String, TabType, CaseIterable, Codable {
  case archived, chats, spaces

  var id: String { rawValue }
  var icon: String {
    switch self {
      case .archived: "archivebox.fill"
      case .chats: "bubble.left.and.bubble.right.fill"
      case .spaces: "building.2.fill"
    }
  }
}

enum Destination: DestinationType, Codable {
  case chats
  case archived
  case spaces
  case space(id: Int64)
  case chat(peer: Peer)
  case chatInfo(chatItem: SpaceChatItem)
  case settings
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
  case integrationOptions(spaceId: Int64, provider: String)
}

enum Sheet: SheetType, Codable {
  case createSpace
  case createThread(spaceId: Int64)
  case alphaSheet

  var id: String {
    switch self {
      case .createSpace:
        "createSpace"
      case let .createThread(spaceId):
        "createThread_\(spaceId)"
      case .alphaSheet:
        "alphaSheet"
    }
  }
}

extension Router {
  func navigateFromNotification(peer: Peer) {
    // Check if user is already in the chat from the notification
    if let currentDestination = self[selectedTab].last,
       case let .chat(currentPeer) = currentDestination,
       currentPeer == peer
    {
      // User is already in the correct chat, no need to navigate
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.popToRoot()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.push(.chat(peer: peer))
      }
    }
  }
}
