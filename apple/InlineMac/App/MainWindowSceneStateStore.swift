import Foundation

enum MainWindowSceneStateStore {
  static let defaultSceneId = "main"

  static func makeSceneId() -> String {
    UUID().uuidString
  }
}
