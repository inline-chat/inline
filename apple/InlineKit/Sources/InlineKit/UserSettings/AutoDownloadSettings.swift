import Combine
import Foundation
import InlineCompat
import Network
import os

public enum AutoDownloadKind: Sendable {
  case media
  case file
  case voice
}

public final class AutoDownloadSettingsManager: ObservableObject, Codable, @unchecked Sendable {
  public static let defaultMediaMaxMB = 25
  public static let defaultFileMaxMB = 10
  public static let defaultVoiceMaxMB = 10
  public static let maxAllowedMB = 2_048

  @Published public var mediaMaxMB: Int
  @Published public var fileMaxMB: Int
  @Published public var voiceMaxMB: Int

  public init(
    mediaMaxMB: Int = AutoDownloadSettingsManager.defaultMediaMaxMB,
    fileMaxMB: Int = AutoDownloadSettingsManager.defaultFileMaxMB,
    voiceMaxMB: Int = AutoDownloadSettingsManager.defaultVoiceMaxMB
  ) {
    self.mediaMaxMB = Self.clamped(mediaMaxMB)
    self.fileMaxMB = Self.clamped(fileMaxMB)
    self.voiceMaxMB = Self.clamped(voiceMaxMB)
  }

  public func shouldDownload(kind: AutoDownloadKind, sizeBytes: Int64?) -> Bool {
    guard let sizeBytes, sizeBytes > 0 else { return false }
    let maxMB = maxMegabytes(for: kind)
    guard maxMB > 0 else { return false }
    return sizeBytes <= Int64(maxMB) * 1_024 * 1_024
  }

  public func maxMegabytes(for kind: AutoDownloadKind) -> Int {
    switch kind {
    case .media:
      Self.clamped(mediaMaxMB)
    case .file:
      Self.clamped(fileMaxMB)
    case .voice:
      Self.clamped(voiceMaxMB)
    }
  }

  public static func clamped(_ value: Int) -> Int {
    min(max(value, 0), maxAllowedMB)
  }

  private enum CodingKeys: String, CodingKey {
    case mediaMaxMB
    case fileMaxMB
    case voiceMaxMB
  }

  public required init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mediaMaxMB = Self.clamped(
      try container.decodeIfPresent(Int.self, forKey: .mediaMaxMB) ?? Self.defaultMediaMaxMB
    )
    fileMaxMB = Self.clamped(
      try container.decodeIfPresent(Int.self, forKey: .fileMaxMB) ?? Self.defaultFileMaxMB
    )
    voiceMaxMB = Self.clamped(
      try container.decodeIfPresent(Int.self, forKey: .voiceMaxMB) ?? Self.defaultVoiceMaxMB
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.clamped(mediaMaxMB), forKey: .mediaMaxMB)
    try container.encode(Self.clamped(fileMaxMB), forKey: .fileMaxMB)
    try container.encode(Self.clamped(voiceMaxMB), forKey: .voiceMaxMB)
  }
}

public enum AutoDownloadPolicy {
  @MainActor
  public static func shouldDownload(kind: AutoDownloadKind, sizeBytes: Int64?) -> Bool {
    guard INUserSettings.current.autoDownload.shouldDownload(kind: kind, sizeBytes: sizeBytes) else { return false }
    // Voice messages are small and expected to play right away; the rest waits for Wi-Fi.
    if kind != .voice, !AutoDownloadNetwork.allowsCellular, AutoDownloadNetwork.isMetered {
      return false
    }
    return true
  }
}

/// Whether auto-download may use cellular data on this device. Low Data Mode counts as cellular.
public enum AutoDownloadNetwork {
  static let defaultsKey = "autoDownload.allowsCellular"

  public static var allowsCellular: Bool {
    get { UserDefaults.shared.object(forKey: defaultsKey) as? Bool ?? true }
    set { UserDefaults.shared.set(newValue, forKey: defaultsKey) }
  }

  /// True on cellular, a personal hotspot, or with Low Data Mode on.
  public static var isMetered: Bool { NetworkCostMonitor.shared.isMetered }
}

final class NetworkCostMonitor: @unchecked Sendable {
  static let shared = NetworkCostMonitor()

  private let monitor = NWPathMonitor()
  private let state = Mutex(false)

  private init() {
    monitor.pathUpdateHandler = { [state] path in
      let metered = path.isExpensive || path.isConstrained
      state.withLock { $0 = metered }
    }
    monitor.start(queue: DispatchQueue(label: "chat.inline.network-cost", qos: .utility))
  }

  var isMetered: Bool { state.withLock { $0 } }
}
