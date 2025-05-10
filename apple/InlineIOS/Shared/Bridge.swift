import Foundation

// let encoder = JSONEncoder()
// let data = try encoder.encode(SharedData())
// try data.write(to: stateFileURL)

//
struct SharedData: Codable {
  var shareExtensionData: [ShareExtensionData]
  var lastUpdate: Date

  init(shareExtensionData: [ShareExtensionData], lastUpdate: Date) {
    self.shareExtensionData = shareExtensionData
    self.lastUpdate = lastUpdate
  }
}

//
//
struct ShareExtensionData: Codable {
  var chats: [SharedChat]
  var users: [SharedUser]

  init(chats: [SharedChat], users: [SharedUser]) {
    self.chats = chats
    self.users = users
  }
}

struct SharedChat: Codable {
  var id: String
  var title: String
  var peerUserId: String?
  var peerThreadId: String?
  init(id: String, title: String, peerUserId: String?, peerThreadId: String?) {
    self.id = id
    self.title = title
    self.peerUserId = peerUserId
    self.peerThreadId = peerThreadId
  }
}

struct SharedUser: Codable {
  var id: String
  var firstName: String
  var lastName: String

  init(id: String, firstName: String, lastName: String) {
    self.id = id
    self.firstName = firstName
    self.lastName = lastName
  }
}

// Bridge manager to handle data exchange
class BridgeManager {
  static let shared = BridgeManager()

  private let sharedContainerIdentifier = "group.chat.inline"

  private var sharedDataURL: URL {
    let containerURL = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)!
    return containerURL.appendingPathComponent("SharedData.json")
  }

  // Save data from main app to be shared with extension
  func saveSharedData(chats: [SharedChat], users: [SharedUser]) {
    let shareExtensionData = ShareExtensionData(chats: chats, users: users)
    print("👽 Saving shared data extension: \(shareExtensionData)")
    let sharedData = SharedData(shareExtensionData: [shareExtensionData], lastUpdate: Date())
    print("👽 Saving sharedData: \(shareExtensionData)")

    do {
      let encoder = JSONEncoder()
      let data = try encoder.encode(sharedData)
      try data.write(to: sharedDataURL)

      print("👽 Shared data saved successfully")
    } catch {
      print("👽 Error saving shared data: \(error)")
    }
  }

  // Load shared data (used by both app and extension)
  func loadSharedData() -> SharedData? {
    do {
      let data = try Data(contentsOf: sharedDataURL)
      let decoder = JSONDecoder()
      print("👽 Loaded data saved successfully")

      return try decoder.decode(SharedData.self, from: data)
    } catch {
      print("👽 Error loading shared data: \(error)")
      return nil
    }
  }
}
