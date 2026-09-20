import Foundation

struct AdminSession: Codable, Sendable {
  let token: String
  let expiresAt: Date
}

enum AdminClientError: Error, LocalizedError, Equatable {
  case rejected(status: Int, code: String)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidResponse: "The admin server returned an unexpected response. Try again."
    case .rejected(_, let code):
      switch code {
      case "invalid_credentials": "The email or password is incorrect."
      case "invalid_totp": "The authenticator code is incorrect or has expired."
      case "login_locked", "too_many_requests": "Too many sign-in attempts. Please wait before trying again."
      case "unauthorized": "Your admin session expired. Please sign in again."
      case "not_allowed": "This account does not have admin access."
      case "password_not_set", "setup_required": "Finish setting up your password and two-factor authentication on the admin website first."
      default: "The admin server could not complete the request. Please try again later."
      }
    }
  }
}

/// Session cookies are bound to the User-Agent on the server; all requests must use the same value.
final class AdminClient: Sendable {
  static let origin = URL(string: "https://admin.inline.chat")!
  static let api = URL(string: "https://api.inline.chat")!
  static let userAgent = "InlineMetrics/macOS/1"
  static let cookieName = "inline_admin_session"
  private let session: URLSession
  private let baseURL: URL

  init(baseURL: URL = AdminClient.api, session: URLSession? = nil) {
    self.baseURL = baseURL
    if let session { self.session = session } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpShouldSetCookies = false
      configuration.httpCookieStorage = nil
      configuration.urlCache = nil
      configuration.timeoutIntervalForRequest = 30
      self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
  }

  func login(email: String, password: String, code: String) async throws -> AdminSession {
    struct Credentials: Encodable { let email: String; let password: String; let totpCode: String }
    let body = try JSONEncoder().encode(Credentials(email: email, password: password, totpCode: code))
    let (_, response) = try await request("auth/login", method: "POST", body: body)
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
      if let key = entry.key as? String, let value = entry.value as? String { result[key] = value }
    }
    guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: headers, for: baseURL)
      .first(where: { $0.name == Self.cookieName }), !cookie.value.isEmpty,
      let expiresAt = cookie.expiresDate, expiresAt > Date()
    else { throw AdminClientError.invalidResponse }
    return AdminSession(token: cookie.value, expiresAt: expiresAt)
  }

  func overview(session: AdminSession) async throws -> OverviewMetrics {
    let (data, _) = try await request("metrics/overview", token: session.token)
    let result = try JSONDecoder().decode(OverviewResponse.self, from: data)
    guard result.ok, result.metrics.reportedAt != nil else { throw AdminClientError.invalidResponse }
    return result.metrics
  }

  func logout(session: AdminSession) async throws {
    _ = try await request("auth/logout", method: "POST", token: session.token)
  }

  private func request(
    _ path: String, method: String = "GET", token: String? = nil, body: Data? = nil
  ) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: baseURL.appendingPathComponent("admin/" + path))
    request.httpMethod = method
    request.httpBody = body
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(Self.origin.absoluteString, forHTTPHeaderField: "Origin")
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let token { request.setValue("\(Self.cookieName)=\(token)", forHTTPHeaderField: "Cookie") }
    let (data, rawResponse) = try await session.data(for: request)
    guard let response = rawResponse as? HTTPURLResponse else { throw AdminClientError.invalidResponse }
    guard (200..<300).contains(response.statusCode) else {
      struct Failure: Decodable { let error: String }
      let code = (try? JSONDecoder().decode(Failure.self, from: data))?.error ?? "unknown"
      throw AdminClientError.rejected(status: response.statusCode, code: code)
    }
    return (data, response)
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    // Never forward an admin credential to a redirect destination.
    completionHandler(nil)
  }
}
