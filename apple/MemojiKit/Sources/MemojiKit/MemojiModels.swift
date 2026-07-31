import Foundation

/// A saved Memoji or stock Animoji and its system-rendered preview.
public enum MemojiKind: String, Hashable, Sendable {
  case saved
  case stockAnimoji
}

public struct Memoji: Identifiable, Hashable, Sendable {
  public let id: String
  public let previewPNGData: Data
  public let kind: MemojiKind

  public init(
    id: String,
    previewPNGData: Data,
    kind: MemojiKind = .saved
  ) {
    self.id = id
    self.previewPNGData = previewPNGData
    self.kind = kind
  }
}

/// An Apple-rendered pose with transparency preserved for later composition.
public struct MemojiPose: Identifiable, Hashable, Sendable {
  public let id: String
  public let memojiID: Memoji.ID
  public let name: String
  public let transparentPNGData: Data
  public let metadata: Data?

  public init(
    id: String,
    memojiID: Memoji.ID,
    name: String,
    transparentPNGData: Data,
    metadata: Data? = nil
  ) {
    self.id = id
    self.memojiID = memojiID
    self.name = name
    self.transparentPNGData = transparentPNGData
    self.metadata = metadata
  }
}

/// The upload-ready output of the picker or headless renderer.
public struct MemojiPhoto: Identifiable, Hashable, Sendable {
  public let id: String
  public let memojiID: Memoji.ID
  public let poseID: MemojiPose.ID?
  public let backgroundID: MemojiBackgroundStyle.ID?
  public let pngData: Data
  public let metadata: Data?

  public init(
    id: String,
    memojiID: Memoji.ID,
    poseID: MemojiPose.ID?,
    backgroundID: MemojiBackgroundStyle.ID?,
    pngData: Data,
    metadata: Data? = nil
  ) {
    self.id = id
    self.memojiID = memojiID
    self.poseID = poseID
    self.backgroundID = backgroundID
    self.pngData = pngData
    self.metadata = metadata
  }

  public init(memoji: Memoji) {
    self.init(
      id: memoji.id,
      memojiID: memoji.id,
      poseID: nil,
      backgroundID: nil,
      pngData: memoji.previewPNGData
    )
  }
}

public struct MemojiRGBAColor: Hashable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  public let alpha: Double

  public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

/// A package-owned background style. Apple renders the pose artwork itself.
public struct MemojiBackgroundStyle: Identifiable, Hashable, Sendable {
  public let id: String
  public let name: String
  public let topColor: MemojiRGBAColor
  public let bottomColor: MemojiRGBAColor
  public let isTransparent: Bool

  public init(
    id: String,
    name: String,
    topColor: MemojiRGBAColor,
    bottomColor: MemojiRGBAColor,
    isTransparent: Bool = false
  ) {
    self.id = id
    self.name = name
    self.topColor = topColor
    self.bottomColor = bottomColor
    self.isTransparent = isTransparent
  }

  public static let presets: [Self] = [
    style("neutral", "Neutral", (0.93, 0.93, 0.95), (0.86, 0.86, 0.89)),
    style("lavender", "Lavender", (0.88, 0.83, 1.00), (0.69, 0.62, 0.94)),
    style("sky", "Sky", (0.76, 0.91, 1.00), (0.43, 0.72, 0.93)),
    style("rose", "Rose", (1.00, 0.80, 0.87), (0.94, 0.49, 0.66)),
    style("sunshine", "Sunshine", (1.00, 0.93, 0.65), (0.96, 0.73, 0.25)),
    style("mint", "Mint", (0.78, 0.96, 0.82), (0.39, 0.78, 0.56)),
    style("blush", "Blush", (0.98, 0.86, 0.84), (0.88, 0.63, 0.61)),
    style("peach", "Peach", (1.00, 0.84, 0.72), (0.96, 0.59, 0.40)),
    style("aqua", "Aqua", (0.72, 0.96, 0.98), (0.25, 0.78, 0.83)),
    style("lime", "Lime", (0.86, 0.97, 0.68), (0.56, 0.79, 0.25)),
    style("stone", "Stone", (0.88, 0.84, 0.79), (0.64, 0.58, 0.51)),
    style("graphite", "Graphite", (0.42, 0.45, 0.50), (0.20, 0.22, 0.26)),
    Self(
      id: "transparent",
      name: "Transparent",
      topColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
      bottomColor: .init(red: 0, green: 0, blue: 0, alpha: 0),
      isTransparent: true
    ),
  ]

  private typealias RGB = (red: Double, green: Double, blue: Double)

  private static func style(
    _ id: String,
    _ name: String,
    _ top: RGB,
    _ bottom: RGB
  ) -> Self {
    Self(
      id: id,
      name: name,
      topColor: .init(red: top.red, green: top.green, blue: top.blue),
      bottomColor: .init(red: bottom.red, green: bottom.green, blue: bottom.blue)
    )
  }
}

public struct MemojiRuntimeAvailability: Equatable, Sendable {
  public let isAvailable: Bool
  public let detail: String

  public init(isAvailable: Bool, detail: String) {
    self.isAvailable = isAvailable
    self.detail = detail
  }
}

public enum MemojiFailureCode: String, Equatable, Sendable {
  case unsupportedPlatform = "unsupported_platform"
  case frameworkUnavailable = "framework_unavailable"
  case runtimeContractChanged = "runtime_contract_changed"
  case noSavedMemoji = "no_saved_memoji"
  case noRenderableMemoji = "no_renderable_memoji"
  case memojiNotFound = "memoji_not_found"
  case noPoses = "no_poses"
  case renderingFailed = "rendering_failed"
  case unexpectedFailure = "unexpected_failure"
}

public enum MemojiError: LocalizedError, Equatable, Sendable {
  case unsupportedPlatform
  case frameworkUnavailable(String)
  case runtimeContractChanged(String)
  case noSavedMemoji
  case noRenderableMemoji(savedRecordCount: Int)
  case memojiNotFound(String)
  case noPoses
  case renderingFailed(String)
  case unexpectedFailure

  public var diagnosticCode: MemojiFailureCode {
    switch self {
    case .unsupportedPlatform: .unsupportedPlatform
    case .frameworkUnavailable: .frameworkUnavailable
    case .runtimeContractChanged: .runtimeContractChanged
    case .noSavedMemoji: .noSavedMemoji
    case .noRenderableMemoji: .noRenderableMemoji
    case .memojiNotFound: .memojiNotFound
    case .noPoses: .noPoses
    case .renderingFailed: .renderingFailed
    case .unexpectedFailure: .unexpectedFailure
    }
  }

  /// A non-user-identifying detail suitable for beta diagnostics.
  public var diagnosticSummary: String {
    switch self {
    case .unsupportedPlatform:
      "The host platform is unsupported."
    case let .frameworkUnavailable(name):
      "The \(name) framework could not be loaded."
    case let .runtimeContractChanged(symbol):
      "The \(symbol) runtime contract was missing or ABI-incompatible."
    case .noSavedMemoji:
      "The avatar data source returned no editable records."
    case let .noRenderableMemoji(savedRecordCount):
      "None of \(savedRecordCount) saved records produced a preview."
    case .memojiNotFound:
      "The selected saved record was no longer present."
    case .noPoses:
      "The sticker renderer produced no synchronous pose images."
    case let .renderingFailed(name):
      "Rendering failed for \(name)."
    case .unexpectedFailure:
      "An unclassified Memoji picker failure occurred."
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unsupportedPlatform:
      "This platform does not have a Memoji runtime adapter yet."
    case let .frameworkUnavailable(name):
      "Apple's private \(name) framework is unavailable."
    case .runtimeContractChanged:
      "Memoji is unavailable on this version of macOS."
    case .noSavedMemoji:
      "No saved Memoji were found for this user."
    case let .noRenderableMemoji(savedRecordCount):
      "Found \(savedRecordCount) saved Memoji, but none could be rendered."
    case .memojiNotFound:
      "The selected Memoji is no longer available. Try reopening the picker."
    case .noPoses:
      "Apple's Memoji runtime returned no pose configurations."
    case .renderingFailed:
      "Apple's Memoji runtime could not render this photo."
    case .unexpectedFailure:
      "Memoji is temporarily unavailable."
    }
  }
}
