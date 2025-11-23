import InlineKit
import SwiftUI

typealias Router = NavigationModel<Destination, Sheet>

enum Destination: DestinationType, Codable {
  case space(id: Int64)
  case chat(peer: Peer)
  case chatInfo(chatItem: SpaceChatItem)
  case settings
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
  case integrationOptions(spaceId: Int64, provider: String)
  case createSpaceChat
  case createThread(spaceId: Int64)
  case archivedChats
  case spacesRoot
}

enum Sheet: SheetType, Codable {
  case createSpace

  case alphaSheet

  case addMember(spaceId: Int64)
  var id: String {
    switch self {
      case .createSpace:
        "createSpace"

      case .alphaSheet:
        "alphaSheet"

      case let .addMember(spaceId):
        "addMember_\(spaceId)"
    }
  }
}

@MainActor
extension Router {
  func navigateFromNotification(peer: Peer) {
    // Check if user is already in the chat from the notification
    if let currentDestination = path.last,
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
