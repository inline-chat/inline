import Foundation
import GRDB
import InlineKit
import Logger
import UIKit

// Class to update shared data when the app launches or before it exits
class AppDataUpdater {
  static let shared = AppDataUpdater()
  private var db: AppDatabase = .shared

  // Update shared data for share extension to use
  func updateSharedData() {
    // Get recent chats and users
    DispatchQueue.global(qos: .background).async {
      self.fetchChatsAndUsers { chats, users in
        if let chats, let users {
          // Save data to shared location
          BridgeManager.shared.saveSharedData(chats: chats, users: users)
        }
      }
    }
  }

  // Fetch recent chats and users from app data
  private func fetchChatsAndUsers(completion: @escaping ([SharedChat]?, [SharedUser]?) -> Void) {
    Task(priority: .background) {
      do {
        // Use GRDB to fetch chats and users similar to HomeViewModel
//        let homeChatItems: [HomeChatItem] = try await db.reader.read { db in
//          try HomeChatItem.all().fetchAll(db)
//        }
        //
        let homeChatItems: [HomeChatItem] = try await db.getHomeChatItems()
        print("👽 homeChatItems: \(homeChatItems)")

        // Convert from GRDB models to Bridge models
        var bridgeChats: [SharedChat] = []
        var bridgeUsers: [SharedUser] = []

        // Process chats
        for item in homeChatItems {
          let chatId = item.dialog.id
          let title = item.user?.user.firstName ?? item.user?.user.fullName

          var peerUserId: Int64? = nil
          var peerThreadId: Int64? = nil

          if let peerId = item.dialog.peerUserId {
            peerUserId = peerId
          } else if let threadId = item.dialog.peerThreadId {
            peerThreadId = threadId
          }

          let bridgeChat = SharedChat(
            id: chatId,
            title: title ?? "",
            peerUserId: peerUserId,
            peerThreadId: peerThreadId
          )

          print("👽 bridgeChat: \(bridgeChat)")
          bridgeChats.append(bridgeChat)

          // Add user info
          let bridgeUser = SharedUser(
            id: item.user?.user.id ?? 0,
            firstName: item.user?.user.firstName ?? "",
            lastName: item.user?.user.lastName ?? ""
          )

          print("👽 bridgeUser: \(bridgeUser)")
          if !bridgeUsers.contains(where: { $0.id == bridgeUser.id }) {
            bridgeUsers.append(bridgeUser)
          }
        }

        // Return the data on the main thread
        DispatchQueue.main.async {
          print("👽 completion called")
          completion(bridgeChats, bridgeUsers)
        }
      } catch {
        Log.shared.error("👽 Error fetching chats and users: \(error)")
        DispatchQueue.main.async {
          completion(nil, nil)
        }
      }
    }
  }
}

// App delegate extensions to register for app lifecycle events
extension UIApplicationDelegate {
  func setupAppDataUpdater() {
    // Update shared data when app launches
    AppDataUpdater.shared.updateSharedData()

    // Register for app will terminate notification
    NotificationCenter.default.addObserver(
      forName: UIApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { _ in
      AppDataUpdater.shared.updateSharedData()
    }

    // Register for app will enter background notification
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      AppDataUpdater.shared.updateSharedData()
    }
  }
}
