import Combine
import Foundation
import InlineKit

class ChatsManager {
  static let shared = ChatsManager()

  private init() {}

  private var memory: [Peer: ChatState] = [:]

  public func get(for peer: Peer, chatId: Int64) -> ChatState {
    if let state = memory[peer] {
      return state
    }

    let state = ChatState(peerId: peer, chatId: chatId)
    memory[peer] = state
    return state
  }
  
  static func get(for peer: Peer, chatId: Int64) -> ChatState {
    shared.get(for: peer, chatId: chatId)
  }
}
