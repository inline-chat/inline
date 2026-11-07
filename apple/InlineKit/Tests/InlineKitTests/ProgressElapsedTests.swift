import Foundation
import Testing

@testable import InlineKit

@Suite("Progress elapsed time")
struct ProgressElapsedTests {
  @Test("formats like the bridge's Worked for line")
  func formats() {
    #expect(ProgressElapsed.text(seconds: 0) == "1s")
    #expect(ProgressElapsed.text(seconds: 8.9) == "8s")
    #expect(ProgressElapsed.text(seconds: 60) == "1m 0s")
    #expect(ProgressElapsed.text(seconds: 132) == "2m 12s")
    #expect(ProgressElapsed.text(seconds: 3661) == "1h 1m")
  }

  @Test("never counts negative and stops past the cap")
  func bounds() {
    let now = Date(timeIntervalSince1970: 1_794_000_000)
    #expect(ProgressElapsed.text(since: now.addingTimeInterval(30), now: now) == "1s")
    #expect(ProgressElapsed.text(since: now.addingTimeInterval(-132), now: now) == "2m 12s")
    #expect(ProgressElapsed.text(since: now.addingTimeInterval(-ProgressElapsed.cap - 1), now: now) == nil)
  }

  @Test("uses the row's own start, else the message time")
  func start() {
    let messageDate = Date(timeIntervalSince1970: 1_794_000_100)
    #expect(ProgressElapsed.start(startedAt: 1_794_000_000, messageDate: messageDate).timeIntervalSince1970 == 1_794_000_000)
    #expect(ProgressElapsed.start(startedAt: nil, messageDate: messageDate) == messageDate)
    #expect(ProgressElapsed.start(startedAt: 0, messageDate: messageDate) == messageDate)
  }
}
