import Combine
import Foundation

public enum UploadPhase: String, Sendable, Equatable {
  case processing
  case uploading
  case completed
  case failed
  case cancelled
}

public struct UploadProgressEvent: Sendable, Equatable {
  public let id: String
  public let phase: UploadPhase
  public let bytesSent: Int64
  public let totalBytes: Int64

  public var fraction: Double {
    guard totalBytes > 0 else { return 0 }
    return min(max(Double(bytesSent) / Double(totalBytes), 0), 1)
  }

  public init(
    id: String,
    phase: UploadPhase,
    bytesSent: Int64 = 0,
    totalBytes: Int64 = 0
  ) {
    self.id = id
    self.phase = phase
    self.bytesSent = bytesSent
    self.totalBytes = totalBytes
  }
}

@MainActor
public final class UploadProgressCenter {
  public static let shared = UploadProgressCenter()

  private var publishers: [String: CurrentValueSubject<UploadProgressEvent, Never>] = [:]

  private init() {}

  public func publisher(for id: String) -> AnyPublisher<UploadProgressEvent, Never> {
    if let publisher = publishers[id] {
      return publisher.eraseToAnyPublisher()
    }

    let initial = UploadProgressEvent(id: id, phase: .uploading, bytesSent: 0, totalBytes: 0)
    let publisher = CurrentValueSubject<UploadProgressEvent, Never>(initial)
    publishers[id] = publisher
    return publisher.eraseToAnyPublisher()
  }

  public func publish(_ event: UploadProgressEvent) {
    if let publisher = publishers[event.id] {
      publisher.send(event)
      return
    }

    let publisher = CurrentValueSubject<UploadProgressEvent, Never>(event)
    publishers[event.id] = publisher
  }

  public func clear(id: String) {
    publishers[id] = nil
  }
}
