import Foundation
import CoreGraphics
import Synchronization
internal import SwiftMathCore

public struct MathColor: Sendable, Hashable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
  }
}

public struct MathRenderRequest: Sendable, Hashable {
  public let tex: String
  public let display: Bool
  public let pointSize: Double
  public let scale: Double
  public let color: MathColor

  public init(tex: String, display: Bool, pointSize: Double, scale: Double, color: MathColor) {
    self.tex = tex; self.display = display; self.pointSize = pointSize; self.scale = scale; self.color = color
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.display == rhs.display && lhs.pointSize == rhs.pointSize && lhs.scale == rhs.scale
      && lhs.color == rhs.color && lhs.tex.utf8.elementsEqual(rhs.tex.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(Data(tex.utf8)); hasher.combine(display); hasher.combine(pointSize)
    hasher.combine(scale); hasher.combine(color)
  }
}

public struct MathImage: Sendable {
  public let image: CGImage
  public let width: CGFloat
  public let ascent: CGFloat
  public let descent: CGFloat
  public let scale: CGFloat
  public var height: CGFloat { ascent + descent }
}

public enum MathRenderFailure: Error, Equatable, Sendable {
  case cancelled, emptySource, sourceLimit, tokenLimit, invalidParameters, fontUnavailable
  case parse(Int), invalidMetrics, rasterLimit, allocationFailed
}

/// One serial owner for mutable upstream types. UI work and attachment creation
/// stay with native callers; this actor returns only immutable pixels/metrics.
public actor MathRenderer {
  public static let shared = MathRenderer()
  private let engine = BoundedMathEngine()
  // The lock protects value-cache bookkeeping only. Font loading, parsing and
  // drawing never hold it, so synchronous layout can only read ready values.
  private nonisolated let cache = Mutex(Cache())

  private init() {}

  public func render(_ request: MathRenderRequest) -> Result<MathImage, MathRenderFailure> {
    guard !Task.isCancelled else { return .failure(.cancelled) }
    let key: Key
    switch Self.key(for: request) {
    case let .success(value): key = value
    case let .failure(error): return .failure(error)
    }
    if let result = cache.withLock({ $0.get(key) }) { return result }
    let color = request.color
    let result = engine.render(tex: request.tex, display: request.display,
                               pointSize: request.pointSize, scale: request.scale,
                               color: CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha))
      .map { MathImage(image: $0.image, width: $0.width, ascent: $0.ascent, descent: $0.descent, scale: $0.scale) }
      .mapError(MathRenderFailure.init)
    guard !Task.isCancelled else { return .failure(.cancelled) }
    cache.withLock { $0.insert(result, for: key) }
    return result
  }

  /// Cache-only synchronous access for native measurement/render passes.
  /// A miss never schedules work, loads fonts, parses, or allocates an image.
  public nonisolated func cachedResult(for request: MathRenderRequest) -> Result<MathImage, MathRenderFailure>? {
    switch Self.key(for: request) {
    case let .success(key): return cache.withLock { $0.get(key) }
    case let .failure(error): return .failure(error)
    }
  }

  /// For memory-pressure handling; callers do not own individual formula jobs.
  public func removeCachedImages() {
    cache.withLock { $0 = Cache() }
  }

  private nonisolated static func key(for request: MathRenderRequest) -> Result<Key, MathRenderFailure> {
    let limit = request.display ? 8192 : 2048
    guard request.tex.utf8.prefix(limit + 1).count <= limit else { return .failure(.sourceLimit) }
    let color = request.color
    guard [color.red, color.green, color.blue, color.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
          request.pointSize.isFinite, (4...96).contains(request.pointSize),
          request.scale.isFinite, (1...4).contains(request.scale)
    else { return .failure(.invalidParameters) }
    return .success(Key(source: Data(request.tex.utf8), display: request.display,
                        pointSize: request.pointSize, scale: request.scale, color: color))
  }

  private struct Cache {
    var entries: [Key: Entry] = [:]
    var bytes = 0
    var sequence: UInt64 = 0

    mutating func get(_ key: Key) -> Result<MathImage, MathRenderFailure>? {
      guard var entry = entries[key] else { return nil }
      sequence &+= 1
      entry.used = sequence
      entries[key] = entry
      return entry.result
    }

    mutating func insert(_ result: Result<MathImage, MathRenderFailure>, for key: Key) {
      let cost: Int
      switch result {
      case let .success(image): cost = image.image.bytesPerRow * image.image.height + key.source.count
      case .failure: cost = key.source.count
      }
      if let prior = entries.removeValue(forKey: key) { bytes -= prior.bytes }
      while entries.count >= 256 || bytes + cost > 32 * 1024 * 1024 {
        guard let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key,
              let removed = entries.removeValue(forKey: oldest) else { break }
        bytes -= removed.bytes
      }
      guard cost <= 32 * 1024 * 1024 else { return }
      sequence &+= 1
      entries[key] = Entry(result: result, bytes: cost, used: sequence)
      bytes += cost
    }
  }

  private struct Key: Hashable {
    // String hashing uses canonical Unicode equivalence; source ranges do not.
    let source: Data
    let display: Bool
    let pointSize: Double
    let scale: Double
    let color: MathColor
  }

  private struct Entry {
    let result: Result<MathImage, MathRenderFailure>
    let bytes: Int
    var used: UInt64
  }
}

private extension MathRenderFailure {
  init(_ failure: CoreMathFailure) {
    switch failure {
    case .emptySource: self = .emptySource
    case .sourceLimit: self = .sourceLimit
    case .tokenLimit: self = .tokenLimit
    case .invalidParameters: self = .invalidParameters
    case .fontUnavailable: self = .fontUnavailable
    case let .parse(code): self = .parse(code)
    case .invalidMetrics: self = .invalidMetrics
    case .rasterLimit: self = .rasterLimit
    case .allocationFailed: self = .allocationFailed
    }
  }
}
