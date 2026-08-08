import Foundation

public enum ThumbnailCohort: String, CaseIterable, Sendable {
  case core
  case structuredText
  case modernDocuments
  case webDocuments
  case appleDocuments
}

public enum ThumbnailSource: String, Sendable {
  case imageIO
  case quickLook
  case plainText
  case delimitedText
  case json
  case markdown
}

public struct ThumbnailArtifact: Sendable, Equatable {
  public let jpegData: Data
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let source: ThumbnailSource

  public init(
    jpegData: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    source: ThumbnailSource
  ) {
    self.jpegData = jpegData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.source = source
  }
}

public struct ThumbnailSystemVersion: Sendable, Equatable {
  public let major: Int
  public let minor: Int

  public init(major: Int, minor: Int = 0) {
    self.major = major
    self.minor = minor
  }

  public static var current: Self {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return Self(major: version.majorVersion, minor: version.minorVersion)
  }
}

public struct ThumbnailPolicy: Sendable {
  public let enabledCohorts: Set<ThumbnailCohort>
  public let maximumPixelSize: Int
  public let minimumDimension: Int
  public let quickLookTimeout: Duration
  public let systemVersion: ThumbnailSystemVersion

  public init(
    enabledCohorts: Set<ThumbnailCohort>,
    maximumPixelSize: Int = 320,
    minimumDimension: Int = 64,
    quickLookTimeout: Duration = .seconds(2),
    systemVersion: ThumbnailSystemVersion = .current
  ) {
    self.enabledCohorts = enabledCohorts
    self.maximumPixelSize = max(1, maximumPixelSize)
    self.minimumDimension = max(1, minimumDimension)
    self.quickLookTimeout = quickLookTimeout
    self.systemVersion = systemVersion
  }
}
