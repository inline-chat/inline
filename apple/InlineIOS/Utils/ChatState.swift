import Foundation
import SwiftUI

@MainActor
final class ChatState: ObservableObject {
  static let shared = ChatState()

  struct State {
    var replyingMessageId: Int64?
  }

  @Published  var states: [Int64: State] = [:]
  @Published private(set) var currentChatId: Int64?

  private let defaults = UserDefaults.standard
  private let statesKey = "chatStates"
  private let currentChatIdKey = "currentChatId"

  init() {
    loadPersistedState()
  }

  func setCurrentChat(id: Int64) {
    if currentChatId != id {
      currentChatId = id
      defaults.set(id, forKey: currentChatIdKey)
    }
  }

  func getState(chatId: Int64) -> State {
    states[chatId] ?? State()
  }

  func setReplyingMessageId(chatId: Int64, id: Int64) {
    var state = getState(chatId: chatId)
    state.replyingMessageId = id
    states[chatId] = state
    persistStates()
  }

  func clearReplyingMessageId(chatId: Int64) {
    var state = getState(chatId: chatId)
    state.replyingMessageId = nil
    states[chatId] = state
    persistStates()
  }

  private func persistStates() {
    let encoded = try? JSONEncoder().encode(states)
    defaults.set(encoded, forKey: statesKey)
  }

  private func loadPersistedState() {
    currentChatId = Int64(defaults.integer(forKey: currentChatIdKey))

    if let data = defaults.data(forKey: statesKey),
       let decoded = try? JSONDecoder().decode([Int64: State].self, from: data)
    {
      states = decoded
    }
  }
}

// Make State codable for persistence
extension ChatState.State: Codable {}
