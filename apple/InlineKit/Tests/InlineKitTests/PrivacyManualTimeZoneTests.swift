import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Manual time zone privacy setting")
struct PrivacyManualTimeZoneTests {
  @Test("hidden and omitted until a server supports it")
  @MainActor
  func unsupportedServer() {
    let fromOldServer = PrivacySettingsManager(from: InlineProtocol.PrivacySettings())
    #expect(!fromOldServer.supportsManualTimeZone)
    #expect(fromOldServer.manualTimeZone == nil)
    #expect(!fromOldServer.toProtocol().hasManualTimeZone)
  }

  @Test("empty is automatic, an identifier is manual, and both are sent back")
  @MainActor
  func automaticAndManual() {
    let manager = PrivacySettingsManager(from: .with { $0.manualTimeZone = "" })
    #expect(manager.supportsManualTimeZone)
    #expect(manager.manualTimeZone == nil)
    #expect(manager.toProtocol().hasManualTimeZone)

    manager.setManualTimeZone(TimeZone(identifier: "Asia/Tokyo"))
    #expect(manager.manualTimeZone?.identifier == "Asia/Tokyo")
    #expect(manager.toProtocol().manualTimeZone == "Asia/Tokyo")

    manager.setManualTimeZone(nil)
    #expect(manager.manualTimeZone == nil)
    #expect(manager.toProtocol().manualTimeZone == "")
  }

  @Test("the choice survives the local cache and server updates")
  @MainActor
  func roundTrips() throws {
    let manager = PrivacySettingsManager(manualTimeZone: "Europe/Berlin")
    let restored = try JSONDecoder().decode(PrivacySettingsManager.self, from: JSONEncoder().encode(manager))
    #expect(restored.manualTimeZone?.identifier == "Europe/Berlin")

    let values = NotificationSettingsValues(InlineProtocol.UserSettings.with {
      $0.privacySettings = .with { $0.manualTimeZone = "America/Toronto" }
    })
    values.apply(to: restored)
    #expect(restored.manualTimeZone?.identifier == "America/Toronto")
  }
}

@Suite("Viewer time zone for local time")
struct ViewerTimeZoneFormatterTests {
  @Test("local time differences use the manual time zone when one is set")
  func comparesWithManualTimeZone() throws {
    let formatter = TimeZoneFormatter()
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    let device = TimeZone.autoupdatingCurrent

    formatter.setViewerTimeZone(identifier: "Asia/Tokyo")
    #expect(formatter.viewerTimeZone.identifier == "Asia/Tokyo")
    #expect(formatter.matchesViewer(timeZoneId: "Asia/Tokyo"))
    #expect(formatter.formatTimeZoneInfo(userTimeZoneId: "Asia/Tokyo") == nil)

    // A peer in UTC+0 reads as 9 hours behind Tokyo whatever this device's zone is.
    let utcInfo = try #require(formatter.formatTimeZoneInfo(userTimeZoneId: "Africa/Abidjan"))
    #expect(tokyo.secondsFromGMT() == 9 * 3_600)
    #expect(utcInfo.hasSuffix("(-9 hr)"))

    formatter.setViewerTimeZone(identifier: "")
    #expect(formatter.viewerTimeZone.identifier == device.identifier)
    formatter.setViewerTimeZone(identifier: nil)
    #expect(formatter.matchesViewer(timeZoneId: device.identifier))
  }
}
