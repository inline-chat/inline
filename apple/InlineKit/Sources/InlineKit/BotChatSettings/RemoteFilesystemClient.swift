import Auth
import Foundation
import InlineProtocol
import RealtimeV2

/// A sheet-lifetime client. It never caches remote paths or imports them into the database.
@MainActor
public struct RemoteFilesystemClient {
  private let accountID: Int64?
  private let peer: Peer
  private let botID: Int64
  private let hostID: String

  public init(peer: Peer, botID: Int64, hostID: String) {
    accountID = Auth.shared.getCurrentUserId()
    self.peer = peer
    self.botID = botID
    self.hostID = hostID
  }

  public func request(path: String, after: String = "", register: Bool = false) async throws -> BotFilesystemResponse {
    guard let accountID, Auth.shared.getCurrentUserId() == accountID else { throw CancellationError() }
    try Task.checkCancellation()
    let response = try await Api.realtime.callRpcDirect(method: .requestBotFilesystem, input: .requestBotFilesystem(.with {
      $0.peerID = peer.toInputPeer()
      $0.botUserID = botID
      $0.hostInstallationID = hostID
      $0.operation = register ? .registerFolder : .list
      $0.path = path
      $0.after = after
    }))
    try Task.checkCancellation()
    guard Auth.shared.getCurrentUserId() == accountID else { throw CancellationError() }
    guard case let .requestBotFilesystem(result)? = response, result.hasResponse else { throw RemoteFilesystemError.invalidResponse }
    return result.response
  }
}

public enum RemoteFilesystemError: Error { case invalidResponse }
