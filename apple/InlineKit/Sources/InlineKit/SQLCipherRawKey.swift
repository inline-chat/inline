import CommonCrypto
import Foundation
import os

/// Supplies SQLCipher keys as raw key data so connections skip the per-connection KDF.
///
/// The stored database key is a random 256-bit secret passed to SQLCipher as a passphrase. SQLCipher 4
/// derives the page key from it with PBKDF2-HMAC-SHA512 (256,000 rounds, ~80 ms on an M-class Mac) on
/// every new connection, and GRDB creates pool readers while holding the pool barrier, so each lazily
/// created reader stalls every other read. Deriving the same key once per process from the passphrase
/// and the file's 16-byte salt, and opening every connection with `x'<key><salt>'`, opens the same file
/// with the same encryption key: no rekey, export or file format change.
enum SQLCipherRawKey {
  /// SQLCipher 4 defaults: PBKDF2-HMAC-SHA512, 256,000 iterations, 32-byte AES-256 key, 16-byte salt.
  static let iterations: UInt32 = 256_000
  static let keyLength = 32
  static let saltLength = 16

  private struct CacheEntry {
    let passphrase: String
    let salt: Data
    let key: Data
  }

  /// The last derived key only: reopening the same database skips the KDF, and keys for passphrases tried
  /// and rejected, or replaced by a rekey, aren't kept for the life of the process.
  private static let lastDerived = OSAllocatedUnfairLock<CacheEntry?>(initialState: nil)

  /// Returns the raw key literal for `passphrase` and the database file at `path`.
  ///
  /// Uses the salt stored in the first 16 bytes of an encrypted file. Returns `nil` for a missing,
  /// unreadable, empty or plaintext file; callers then key with the passphrase, and switch to the raw
  /// key once SQLCipher has written the new file's salt.
  static func literal(passphrase: String, databasePath path: String) -> String? {
    guard let salt = salt(forDatabaseAt: path) else { return nil }
    return literal(passphrase: passphrase, salt: salt)
  }

  static func literal(passphrase: String, salt: Data) -> String? {
    guard let key = derivedKey(passphrase: passphrase, salt: salt) else { return nil }
    return "x'" + hex(key + salt) + "'"
  }

  /// A raw key literal without salt, for `sqlite3_rekey`: rekey keeps the file's current salt.
  static func rekeyLiteral(passphrase: String, salt: Data) -> String? {
    guard let key = derivedKey(passphrase: passphrase, salt: salt) else { return nil }
    return "x'" + hex(key) + "'"
  }

  static func salt(forDatabaseAt path: String) -> Data? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: saltLength), header.count == saltLength else {
      // An empty file (created but never written) has no salt yet. Let SQLCipher choose one.
      return nil
    }
    // A plaintext SQLite file starts with "SQLite format 3\0"; it has no salt to derive from.
    if header == Data("SQLite format 3\u{0}".utf8) {
      return nil
    }
    return header
  }

  static func derivedKey(passphrase: String, salt: Data) -> Data? {
    // SQLCipher treats an empty key as no encryption; there is nothing to derive.
    guard salt.count == saltLength, !passphrase.isEmpty else { return nil }
    if let cached = lastDerived.withLock({ entry in
      entry.flatMap { $0.passphrase == passphrase && $0.salt == salt ? $0.key : nil }
    }) {
      return cached
    }
    let password = Array(passphrase.utf8)
    var key = Data(count: keyLength)
    let status = key.withUnsafeMutableBytes { keyBytes in
      salt.withUnsafeBytes { saltBytes in
        password.withUnsafeBufferPointer { passwordBytes in
          passwordBytes.baseAddress!.withMemoryRebound(to: Int8.self, capacity: passwordBytes.count) { passwordPointer in
            CCKeyDerivationPBKDF(
              CCPBKDFAlgorithm(kCCPBKDF2),
              passwordPointer,
              passwordBytes.count,
              saltBytes.bindMemory(to: UInt8.self).baseAddress!,
              saltLength,
              CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
              iterations,
              keyBytes.bindMemory(to: UInt8.self).baseAddress!,
              keyLength
            )
          }
        }
      }
    }
    guard status == kCCSuccess else { return nil }
    let derived = key
    lastDerived.withLock { $0 = CacheEntry(passphrase: passphrase, salt: salt, key: derived) }
    return derived
  }

  private static func hex(_ data: Data) -> String {
    let digits = Array("0123456789ABCDEF".utf8)
    var out = [UInt8]()
    out.reserveCapacity(data.count * 2)
    for byte in data {
      out.append(digits[Int(byte >> 4)])
      out.append(digits[Int(byte & 0x0F)])
    }
    return String(bytes: out, encoding: .utf8) ?? ""
  }
}
