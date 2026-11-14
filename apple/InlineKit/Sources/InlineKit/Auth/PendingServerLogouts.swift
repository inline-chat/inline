import Foundation
import InlineNotificationFence
import Logger
import Security

/// Server sign-out that survives a failed request, an app kill, or a logout that never contacted
/// the server (account recovery, a resumed logout). Until the server revokes a session it keeps
/// pushing that account's messages to this device, where the notification extension can only
/// withhold them as "Open Inline to read it." Every signed-out bearer token stays here until the
/// server has answered for it.
public actor PendingServerLogouts {
  public static let shared = PendingServerLogouts(storage: KeychainPendingServerLogoutStorage())

  struct Entry: Codable, Equatable, Sendable {
    var token: String
    var createdAt: Date
  }

  /// Older tokens have long expired or been revoked server side; stop retrying them.
  static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
  static let maximumEntries = 8

  private let storage: any PendingServerLogoutStorage
  private let signOut: @Sendable (String) async throws -> Void
  private let now: @Sendable () -> Date
  private var isDraining = false

  init(
    storage: any PendingServerLogoutStorage,
    signOut: @escaping @Sendable (String) async throws -> Void = { token in
      _ = try await ApiClient.shared.logout(bearerToken: token, timeoutInterval: 15)
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.storage = storage
    self.signOut = signOut
    self.now = now
  }

  /// Persists the token for `drain`. Awaited by logout before it destroys the credentials.
  public func enqueue(token: String) {
    var entries = storage.load()
    guard !entries.contains(where: { $0.token == token }) else { return }
    entries.append(Entry(token: token, createdAt: now()))
    entries = Array(entries.suffix(Self.maximumEntries))
    if !storage.save(entries) {
      Log.shared.error("Pending server logout could not be persisted")
    }
  }

  /// Retries every pending sign-out. Called after logout, on launch and on activation.
  public func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }

    let cutoff = now().addingTimeInterval(-Self.maximumAge)
    for entry in storage.load() {
      let settled: Bool
      if entry.createdAt < cutoff {
        settled = true
      } else {
        do {
          try await signOut(entry.token)
          settled = true
        } catch {
          settled = Self.serverAnswered(error)
          if !settled {
            Log.shared.warning("Server logout will be retried: \(error.localizedDescription)")
          }
        }
      }
      if settled {
        _ = storage.save(storage.load().filter { $0.token != entry.token })
      }
    }
  }

  /// The server rejected the request itself (for example an already revoked session). Only
  /// transport failures, timeouts, rate limits and server errors are worth retrying.
  static func serverAnswered(_ error: Error) -> Bool {
    switch error as? APIError {
    case let .httpError(statusCode):
      (400 ..< 500).contains(statusCode) && statusCode != 408
    case .error, .decodingError:
      true
    default:
      false
    }
  }
}

protocol PendingServerLogoutStorage: Sendable {
  func load() -> [PendingServerLogouts.Entry]
  func save(_ entries: [PendingServerLogouts.Entry]) -> Bool
}

/// Device-only keychain item, named per install (see `InlineInstallNamespace`).
struct KeychainPendingServerLogoutStorage: PendingServerLogoutStorage {
  static let service = "chat.inline.pending-server-logout"
  static let account = InlineInstallNamespace.scoped("tokens-v1")

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: Self.account,
    ]
  }

  func load() -> [PendingServerLogouts.Entry] {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
      return []
    }
    return (try? JSONDecoder().decode([PendingServerLogouts.Entry].self, from: data)) ?? []
  }

  func save(_ entries: [PendingServerLogouts.Entry]) -> Bool {
    if entries.isEmpty {
      let status = SecItemDelete(baseQuery as CFDictionary)
      return status == errSecSuccess || status == errSecItemNotFound
    }
    guard let data = try? JSONEncoder().encode(entries) else { return false }
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      status = SecItemAdd(baseQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
    }
    return status == errSecSuccess
  }
}
