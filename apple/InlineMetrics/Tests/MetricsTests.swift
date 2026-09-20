import Foundation
import Testing
@testable import InlineMetricsCore

private let overviewJSON = """
{"ok":true,"metrics":{"dau":12,"wau":30,"messagesToday":456,"waitlistCount":99,
"newUsersLastDay":4,"newWaitlistLastDay":8,"asOf":"2026-09-20T12:00:00.000Z",
"reportingTimeZone":"UTC","dailyActivity":[
{"date":"2026-09-18T00:00:00.000Z","activeUsers":18,"messages":400,"newUsers":2},
{"date":"2026-09-19T00:00:00.000Z","activeUsers":24,"messages":600,"newUsers":2},
{"date":"2026-09-20T00:00:00.000Z","activeUsers":12,"messages":456,"newUsers":4}],
"mrr":390,"recentUsersLastDay":[{"email":"private@example.com"}]}}
"""

@Suite(.serialized)
struct MetricsTests {
  @Test func decodesServerResponseWithoutPersistingPrivateFields() throws {
    let response = try JSONDecoder().decode(OverviewResponse.self, from: Data(overviewJSON.utf8))
    #expect(response.metrics.dau == 12)
    #expect(response.metrics.wau == 30)
    #expect(response.metrics.reportedAt != nil)
    #expect(response.metrics.dailyActivity.last?.activeUsers == 12)
    let encoded = String(decoding: try JSONEncoder().encode(response.metrics), as: UTF8.self)
    #expect(!encoded.contains("private@example.com"))
    #expect(!encoded.contains("mrr"))
    #expect(!encoded.contains("recentUsers"))
  }

  @Test func fullServerTimestampsProduceSeparateChronologicalChartBars() throws {
    let metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(overviewJSON.utf8)).metrics
    let days = metrics.chartDays
    #expect(days.count == 3)
    #expect(Set(days.map(\.id)).count == 3)
    #expect(days[1].date.timeIntervalSince(days[0].date) == 86_400)
    #expect(days[2].date.timeIntervalSince(days[1].date) == 86_400)
    #expect(days.allSatisfy { !$0.label.contains(".000Z") })
    #expect(days.map(\.activity.activeUsers) == [18, 24, 12])
  }

  @Test func acceptsLegacyDateOnlyAndTimestampFormatsWithoutTimezoneDrift() {
    let midnight = MetricsDate.parse("2026-09-20T00:00:00.000Z")
    #expect(midnight != nil)
    #expect(MetricsDate.parse("2026-09-20") == midnight)
    #expect(MetricsDate.parse("2026-09-20T00:00:00Z") == midnight)
    #expect(MetricsDate.parse("2026-09-20T03:30:00+03:30") == midnight)
    #expect(MetricsDate.parse("not-a-date") == nil)
  }

  @Test func changesUseYesterdayAndHandleBothDirections() throws {
    let metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(overviewJSON.utf8)).metrics
    #expect(metrics.activeUsersChange?.direction == -1)
    #expect(metrics.activeUsersChange?.percentage == -50)
    #expect(metrics.messagesChange?.percentage == -24)
    #expect(metrics.newUsersChange?.direction == 1)
    #expect(metrics.newUsersChange?.percentage == 100)
  }

  @Test func missingYesterdayDoesNotCompareAgainstAnArbitraryOlderDay() throws {
    let json = overviewJSON.replacingOccurrences(of: "2026-09-19T00:00:00.000Z", with: "2026-09-17T00:00:00.000Z")
    let metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(json.utf8)).metrics
    #expect(metrics.activeUsersChange == nil)
    #expect(metrics.messagesChange == nil)
  }

  @Test func handlesZeroBaselineAndUnchangedCountsWithoutInfinitePercentages() {
    #expect(MetricChange(current: 5, previous: 0).text == "New")
    #expect(MetricChange(current: 5, previous: 0).percentage == nil)
    #expect(MetricChange(current: 0, previous: 0).direction == 0)
    #expect(MetricChange(current: 0, previous: 0).text == "—")
    #expect(MetricChange(current: 0, previous: 5).percentage == -100)
    #expect(MetricChange(current: 100_001, previous: 100_000).text == "<0.1%")
  }

  @Test func chartSortsDeduplicatesAndDiscardsInvalidDates() throws {
    let json = overviewJSON.replacingOccurrences(of: "2026-09-18T00:00:00.000Z", with: "2026-09-20")
    let metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(json.utf8)).metrics
    #expect(metrics.chartDays.count == 2)
    #expect(metrics.chartDays.last?.activity.activeUsers == 12)
    let invalid = json.replacingOccurrences(of: "2026-09-19T00:00:00.000Z", with: "invalid")
    let invalidMetrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(invalid.utf8)).metrics
    #expect(invalidMetrics.chartDays.count == 1)
  }

  @Test func oldSavedSnapshotsDecodeWithoutInventingMissingComparisons() throws {
    let day = try JSONDecoder().decode(DailyActivity.self, from: Data("{\"date\":\"2026-09-19\",\"activeUsers\":9}".utf8))
    #expect(day.messages == nil)
    #expect(day.newUsers == nil)
  }

  @Test func reloadsImmediatelyOnDataChangesAndPeriodicallyWhenUnchanged() throws {
    let now = Date()
    let metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(overviewJSON.utf8)).metrics
    let previous = MetricsSnapshot(state: .ready, metrics: metrics, fetchedAt: now, sessionExpiresAt: now.addingTimeInterval(3600))
    let timestampOnly = overviewJSON.replacingOccurrences(of: "12:00:00.000Z", with: "12:05:00.000Z")
    var next = previous
    next.metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(timestampOnly.utf8)).metrics
    #expect(!next.needsWidgetReload(comparedTo: previous, lastReload: now, now: now.addingTimeInterval(300)))
    #expect(next.needsWidgetReload(comparedTo: previous, lastReload: now, now: now.addingTimeInterval(900)))
    let newMessage = timestampOnly.replacingOccurrences(of: "\"messagesToday\":456", with: "\"messagesToday\":457")
    next.metrics = try JSONDecoder().decode(OverviewResponse.self, from: Data(newMessage.utf8)).metrics
    #expect(next.needsWidgetReload(comparedTo: previous, lastReload: now, now: now.addingTimeInterval(300)))
    next = .signedOut
    #expect(next.needsWidgetReload(comparedTo: previous, lastReload: now, now: now))
  }

  @Test func expiryHidesMetricsEvenWhenCompanionIsNotRunning() {
    var snapshot = MetricsSnapshot.sample
    let expiry = Date(timeIntervalSince1970: 1_000)
    snapshot.sessionExpiresAt = expiry
    #expect(snapshot.visibleMetrics(at: expiry.addingTimeInterval(-1)) != nil)
    #expect(snapshot.visibleMetrics(at: expiry) == nil)
    #expect(snapshot.status(at: expiry) == "Sign in again")
    snapshot.state = .unavailable
    #expect(snapshot.visibleMetrics(at: expiry) == nil)
  }

  @Test func failureKeepsSavedCountsButLabelsThemAndSignOutHidesThem() {
    var snapshot = MetricsSnapshot.sample
    snapshot.state = .unavailable
    #expect(snapshot.visibleMetrics(at: Date()) != nil)
    #expect(snapshot.status(at: Date()).contains("Offline"))
    snapshot.state = .signedOut
    #expect(snapshot.visibleMetrics(at: Date()) == nil)
  }

  @Test func staleBoundaryIsExplicit() {
    var snapshot = MetricsSnapshot.sample
    let fetched = Date()
    snapshot.fetchedAt = fetched
    #expect(snapshot.status(at: fetched.addingTimeInterval(2699)) == "Updated")
    #expect(snapshot.status(at: fetched.addingTimeInterval(2700)) == "Open Inline Metrics to update")
  }

  @Test func snapshotRoundTripAndLogoutEraseCachedMetrics() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
    #expect(store.read().state == .signedOut)
    try store.write(.sample)
    #expect(store.read().metrics?.dau == 128)
    try store.write(.signedOut)
    #expect(store.read().metrics == nil)
    let saved = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!saved.contains("128"))
    try Data("corrupt".utf8).write(to: store.fileURL)
    #expect(store.read().state == .signedOut)
  }

  @Test func loginExtractsCookieAndAuthenticatedRequestUsesSameUserAgent() async throws {
    StubProtocol.stub.set { request in
      #expect(request.value(forHTTPHeaderField: "Origin") == "https://admin.inline.chat")
      #expect(request.value(forHTTPHeaderField: "User-Agent") == AdminClient.userAgent)
      #expect(request.url?.host == "api.inline.chat")
      if request.url?.path == "/admin/auth/login" {
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        return (200, ["Set-Cookie": "inline_admin_session=42:test-token; Max-Age=259200; Path=/; Secure; HttpOnly; SameSite=Strict"], "{\"ok\":true}")
      }
      #expect(request.url?.path == "/admin/metrics/overview")
      #expect(request.value(forHTTPHeaderField: "Cookie") == "inline_admin_session=42:test-token")
      return (200, [:], overviewJSON)
    }
    let client = makeClient()
    let session = try await client.login(email: "admin@example.com", password: "test-password", code: "123456")
    #expect(session.token == "42:test-token")
    #expect(session.expiresAt > Date())
    let metrics = try await client.overview(session: session)
    #expect(metrics.messagesToday == 456)
  }

  @Test func missingSessionCookieIsRejected() async {
    StubProtocol.stub.set { _ in (200, [:], "{\"ok\":true}") }
    await #expect(throws: AdminClientError.invalidResponse) {
      _ = try await makeClient().login(email: "admin@example.com", password: "test-password", code: "123456")
    }
  }

  @Test func authenticationFailureIsDistinctFromServerFailure() async {
    StubProtocol.stub.set { _ in (401, [:], "{\"ok\":false,\"error\":\"unauthorized\"}") }
    await #expect(throws: AdminClientError.rejected(status: 401, code: "unauthorized")) {
      _ = try await makeClient().overview(session: testSession)
    }
    StubProtocol.stub.set { _ in (503, [:], "temporarily unavailable") }
    await #expect(throws: AdminClientError.rejected(status: 503, code: "unknown")) {
      _ = try await makeClient().overview(session: testSession)
    }
  }

  @Test func rejectsMalformedMetricsInsteadOfDisplayingZeroes() async {
    StubProtocol.stub.set { _ in (200, [:], "{\"ok\":true,\"metrics\":{}}") }
    await #expect(throws: DecodingError.self) {
      _ = try await makeClient().overview(session: testSession)
    }
  }

  @Test func logoutUsesCurrentSessionAndPost() async throws {
    StubProtocol.stub.set { request in
      #expect(request.url?.path == "/admin/auth/logout")
      #expect(request.httpMethod == "POST")
      #expect(request.value(forHTTPHeaderField: "Cookie") == "inline_admin_session=test-token")
      return (200, [:], "{\"ok\":true}")
    }
    try await makeClient().logout(session: testSession)
  }

  private var testSession: AdminSession {
    AdminSession(token: "test-token", expiresAt: Date().addingTimeInterval(3600))
  }

  private func makeClient() -> AdminClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    return AdminClient(session: URLSession(configuration: config))
  }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
  typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], String)
  final class Stub: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: Handler = { _ in (500, [:], "") }
    func set(_ handler: @escaping Handler) { lock.withLock { self.handler = handler } }
    func response(for request: URLRequest) -> (Int, [String: String], String) {
      let callback = lock.withLock { handler }
      return callback(request)
    }
  }
  static let stub = Stub()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (status, headers, body) = Self.stub.response(for: request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
