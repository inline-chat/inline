import Foundation
import InlineKit
import SwiftUI

@MainActor
final class ChatState: ObservableObject {
  static let shared = ChatState()

  struct State {
    var replyingMessageId: Int64?
  }

  @Published var states: [Peer: State] = [:]
  @Published private(set) var currentPeer: Peer?

  private let defaults = UserDefaults.standard
  private let statesKey = "chatStates"
  private let currentPeerKey = "currentPeer"

  init() {
    loadPersistedState()
  }

  func setCurrentChat(peer: Peer) {
    if currentPeer != peer {
      currentPeer = peer
      if let encoded = try? JSONEncoder().encode(peer) {
        defaults.set(encoded, forKey: currentPeerKey)
      }
    }
  }

  func getState(peer: Peer) -> State {
    states[peer] ?? State()
  }

  func setReplyingMessageId(peer: Peer, id: Int64) {
    var state = getState(peer: peer)
    state.replyingMessageId = id
    print("Setting replying message id to \(id)")
    states[peer] = state
    persistStates()
    NotificationCenter.default.post(name: .init("ChatStateDidChange"), object: nil)
  }

  func clearReplyingMessageId(peer: Peer) {
    var state = getState(peer: peer)
    state.replyingMessageId = nil
    states[peer] = state
    persistStates()
    NotificationCenter.default.post(name: .init("ChatStateDidChange"), object: nil)
  }

  private func persistStates() {
    let encoded = try? JSONEncoder().encode(states)
    defaults.set(encoded, forKey: statesKey)
  }

  private func loadPersistedState() {
    if let data = defaults.data(forKey: currentPeerKey),
       let decoded = try? JSONDecoder().decode(Peer.self, from: data)
    {
      currentPeer = decoded
    }

    if let data = defaults.data(forKey: statesKey),
       let decoded = try? JSONDecoder().decode([Peer: State].self, from: data)
    {
      states = decoded
    }
  }
}

// Make State codable for persistence
extension ChatState.State: Codable {}
