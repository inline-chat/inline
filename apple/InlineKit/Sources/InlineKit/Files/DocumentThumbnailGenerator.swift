import Foundation
import InlineThumbnailing
import Logger

public struct DocumentThumbnailArtifact: Sendable {
  public let jpegData: Data
  public let pixelWidth: Int
  public let pixelHeight: Int

  public init(jpegData: Data, pixelWidth: Int, pixelHeight: Int) {
    self.jpegData = jpegData
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
  }
}

public enum DocumentThumbnailFeatureCohort: String, CaseIterable, Sendable {
  case core
  case structuredText
  case modernDocuments
  case webDocuments
  case appleDocuments
}

public enum DocumentThumbnailFeatureFlags {
  public static let enabledKey = "documentThumbnails.enabled"

  public static var enabled: Bool {
    get { resolvedBool(forKey: enabledKey, default: true) }
    set { UserDefaults.shared.set(newValue, forKey: enabledKey) }
  }

  public static func isEnabled(_ cohort: DocumentThumbnailFeatureCohort) -> Bool {
    guard enabled else { return false }
    return resolvedBool(forKey: key(for: cohort), default: defaultEnabled(cohort))
  }

  public static func setEnabled(_ enabled: Bool, for cohort: DocumentThumbnailFeatureCohort) {
    UserDefaults.shared.set(enabled, forKey: key(for: cohort))
  }

  public static func key(for cohort: DocumentThumbnailFeatureCohort) -> String {
    "documentThumbnails.cohort.\(cohort.rawValue)"
  }

  private static func defaultEnabled(_ cohort: DocumentThumbnailFeatureCohort) -> Bool {
    switch cohort {
    case .core, .structuredText, .modernDocuments, .webDocuments:
      true
    case .appleDocuments:
      false
    }
  }

  private static func resolvedBool(forKey key: String, default defaultValue: Bool) -> Bool {
    guard UserDefaults.shared.object(forKey: key) != nil else { return defaultValue }
    return UserDefaults.shared.bool(forKey: key)
  }
}

public enum DocumentThumbnailIntegration {
  private static let thumbnailer = DocumentThumbnailer()
  private static let log = Log.scoped("DocumentThumbnailIntegration")

  /// Lets compose reserve final thumbnail geometry without starting generation
  /// or reading the file. Generation can still fail softly afterward.
  public static func canAttemptGeneration(at url: URL) -> Bool {
    let enabledCohorts = enabledCohorts()
    guard !enabledCohorts.isEmpty else { return false }
    return thumbnailer.canAttemptThumbnail(
      for: url,
      policy: ThumbnailPolicy(enabledCohorts: enabledCohorts)
    )
  }

  public static func generate(at url: URL) async -> DocumentThumbnailArtifact? {
    let enabledCohorts = enabledCohorts()
    guard !enabledCohorts.isEmpty else { return nil }

    let start = ContinuousClock.now
    guard let artifact = await thumbnailer.thumbnail(
      for: url,
      policy: ThumbnailPolicy(enabledCohorts: enabledCohorts)
    ) else {
      log.debug(
        "Document thumbnail unavailable format=\(logFormat(for: url)) " +
          "duration=\(start.duration(to: .now))"
      )
      return nil
    }

    log.debug(
      "Generated document thumbnail format=\(logFormat(for: url)) source=\(artifact.source.rawValue) " +
        "size=\(artifact.pixelWidth)x\(artifact.pixelHeight) duration=\(start.duration(to: .now))"
    )
    return DocumentThumbnailArtifact(
      jpegData: artifact.jpegData,
      pixelWidth: artifact.pixelWidth,
      pixelHeight: artifact.pixelHeight
    )
  }

  static func generateImmediately(at url: URL) -> DocumentThumbnailArtifact? {
    let enabledCohorts = enabledCohorts()
    guard !enabledCohorts.isEmpty,
          let artifact = thumbnailer.immediateThumbnail(
            for: url,
            policy: ThumbnailPolicy(enabledCohorts: enabledCohorts)
          )
    else {
      return nil
    }
    return DocumentThumbnailArtifact(
      jpegData: artifact.jpegData,
      pixelWidth: artifact.pixelWidth,
      pixelHeight: artifact.pixelHeight
    )
  }

  private static func enabledCohorts() -> Set<ThumbnailCohort> {
    Set(
      DocumentThumbnailFeatureCohort.allCases.compactMap { cohort in
        guard DocumentThumbnailFeatureFlags.isEnabled(cohort) else { return nil }
        return ThumbnailCohort(rawValue: cohort.rawValue)
      }
    )
  }

  private static func logFormat(for url: URL) -> String {
    let fileExtension = url.pathExtension.lowercased()
    return fileExtension.isEmpty ? "none" : fileExtension
  }
}
