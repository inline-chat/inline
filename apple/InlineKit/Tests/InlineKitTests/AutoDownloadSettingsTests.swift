import Testing

@testable import InlineKit

@Suite("Auto-download settings")
struct AutoDownloadSettingsTests {
  @Test("Uses production defaults")
  func defaults() {
    let settings = AutoDownloadSettingsManager()

    #expect(settings.mediaMaxMB == 25)
    #expect(settings.fileMaxMB == 10)
    #expect(settings.voiceMaxMB == 10)
  }

  @Test("Treats zero threshold as disabled")
  func disabledThreshold() {
    let settings = AutoDownloadSettingsManager(mediaMaxMB: 0, fileMaxMB: 0, voiceMaxMB: 0)

    #expect(settings.shouldDownload(kind: .media, sizeBytes: 1) == false)
    #expect(settings.shouldDownload(kind: .file, sizeBytes: 1) == false)
    #expect(settings.shouldDownload(kind: .voice, sizeBytes: 1) == false)
  }

  @Test("Downloads files at or below threshold")
  func belowThreshold() {
    let settings = AutoDownloadSettingsManager(mediaMaxMB: 1, fileMaxMB: 2, voiceMaxMB: 3)

    #expect(settings.shouldDownload(kind: .media, sizeBytes: 1_024 * 1_024))
    #expect(settings.shouldDownload(kind: .file, sizeBytes: 2 * 1_024 * 1_024))
    #expect(settings.shouldDownload(kind: .voice, sizeBytes: 3 * 1_024 * 1_024))
  }

  @Test("Skips files above threshold or unknown size")
  func aboveThreshold() {
    let settings = AutoDownloadSettingsManager(mediaMaxMB: 1, fileMaxMB: 1, voiceMaxMB: 1)

    #expect(settings.shouldDownload(kind: .media, sizeBytes: 1_024 * 1_024 + 1) == false)
    #expect(settings.shouldDownload(kind: .file, sizeBytes: nil) == false)
    #expect(settings.shouldDownload(kind: .voice, sizeBytes: 0) == false)
  }

  @Test("Clamps invalid values")
  func clampsValues() {
    let settings = AutoDownloadSettingsManager(mediaMaxMB: -1, fileMaxMB: 4_096, voiceMaxMB: 8)

    #expect(settings.mediaMaxMB == 0)
    #expect(settings.fileMaxMB == AutoDownloadSettingsManager.maxAllowedMB)
    #expect(settings.voiceMaxMB == 8)
  }
}
