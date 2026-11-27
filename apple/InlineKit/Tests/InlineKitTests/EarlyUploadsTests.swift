import Foundation
import Testing
@testable import InlineKit

@Suite("Early upload switch", .serialized)
struct EarlyUploadSettingsTests {
  @Test("early upload is on unless switched off")
  func defaultsOnAndCanBeSwitchedOff() {
    let defaults = UserDefaults.standard
    let key = EarlyUploadSettings.enabledKey
    let previous = defaults.object(forKey: key)
    defer {
      if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    defaults.removeObject(forKey: key)
    #expect(EarlyUploadSettings.isEnabled)
    defaults.set(false, forKey: key)
    #expect(EarlyUploadSettings.isEnabled == false)
    defaults.set(true, forKey: key)
    #expect(EarlyUploadSettings.isEnabled)
  }
}
