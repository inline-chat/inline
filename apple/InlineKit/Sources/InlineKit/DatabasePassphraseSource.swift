import GRDB
import Synchronization

/// Per-pool passphrase state used when GRDB prepares writer and reader connections.
///
/// A `DatabasePool` may prepare new reader connections after its database has been
/// rekeyed. The configuration must therefore read the current key instead of retaining
/// the key that originally opened the pool.
final class DatabasePassphraseSource: Sendable {
  private let storage: Mutex<String>

  init(_ passphrase: String) {
    storage = Mutex(passphrase)
  }

  func passphraseForConnectionPreparation() -> String {
    storage.withLock { $0 }
  }

  /// Replaces the key used for subsequently prepared connections and returns the old key.
  /// The caller can restore the old key if the database rekey operation fails.
  @discardableResult
  func replace(with passphrase: String) -> String {
    storage.withLock { current in
      let previous = current
      current = passphrase
      return previous
    }
  }
}

extension AppDatabase {
  /// Builds a GRDB configuration whose connections read from a pool-scoped key source.
  ///
  /// This exploratory overload is intentionally not wired into `AppDatabase.shared` yet.
  static func makeConfiguration(
    passphraseSource: DatabasePassphraseSource,
    _ base: Configuration = Configuration()
  ) -> Configuration {
    var config = base
    config.prepareDatabase { db in
      db.trace(options: .statement) { log.trace($0.expandedDescription) }
      try db.usePassphrase(passphraseSource.passphraseForConnectionPreparation())
    }
    return config
  }
}
