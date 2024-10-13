import Combine
import Foundation

public enum APIError: Error {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingError(Error)
    case networkError
    case rateLimited
}

public enum Path: String {
    case verifyCode = "verify-email-code"
    case sendCode = "send-email-code"
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
    public static let shared = ApiClient()
    public init() {}
    var baseURL: String {
        #if targetEnvironment(simulator)
            return "http://localhost:8000/v001"
        #elseif DEBUG
            return "http://192.168.3.122:8000/v001"
        #else
            return "https://headline.inline.chat/v001"
        #endif
    }

    private let decoder = JSONDecoder()

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

            switch httpResponse.statusCode {
            case 200 ... 299:
                return try decoder.decode(T.self, from: data)
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.httpError(statusCode: httpResponse.statusCode)
            }
        } catch let decodingError as DecodingError {
            throw APIError.decodingError(decodingError)
        } catch let apiError as APIError {
            throw apiError
        } catch {
            throw APIError.networkError
        }
    }

    // MARK: AUTH

    public func sendCode(email: String) async throws {
        let _: SendCodeResponse = try await request(.sendCode, queryItems: [URLQueryItem(name: "email", value: email)])
    }

    public func verifyCode(code: String, email: String) async throws -> VerifyCodeResponse {
        try await request(.verifyCode, queryItems: [URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email)])
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
