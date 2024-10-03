import Combine
import Foundation

public enum APIError: Error {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
}

public enum Path: String {
    case verifyCode = "verify-email-code"
    case sendCode = "send-email-code"
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
    public static let shared = ApiClient()
    public init() {}
    var baseURL: String {
        #if DEBUG
            return "http://localhost:8000/v001"
        #else
            return "https://headline.inline.chat/v001"
        #endif
    }

    private let decoder = JSONDecoder()

    // Use for base URL of your API requests
    private func request<T: Decodable>(_ path: Path, queryItems: [URLQueryItem] = []) async throws -> T {
        guard var urlComponents = URLComponents(string: "\(baseURL)/auth/\(path.rawValue)") else {
            throw APIError.invalidURL
        }

        urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = urlComponents.url else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw APIError.httpError(statusCode: httpResponse.statusCode)
            }

            let decodedData = try decoder.decode(T.self, from: data)
            return decodedData
        } catch {
            Log.shared.error("Failed to request", error: error, scope: .api)
            throw error
        }
    }

    // MARK: AUTH

    public func sendCode(email: String) async throws {
        let result: SendCodeResponse = try await request(.sendCode, queryItems: [URLQueryItem(name: "email", value: email)])
    }

    public func verifyCode(code: String, email: String) async throws -> VerifyCodeResponse {
        let result: VerifyCodeResponse = try await request(.verifyCode, queryItems: [URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email)])
        return result
    }
}

public struct VerifyCodeResponse: Codable {
    public let ok: Bool
    public let userId: String
    public let token: String
}

public struct SendCodeResponse: Codable {
    let ok: Bool
}
