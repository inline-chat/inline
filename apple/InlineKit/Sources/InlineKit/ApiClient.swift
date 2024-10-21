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
    case verifyCode = "verifyEmailCode"
    case sendCode = "sendEmailCode"
    case createSpace
}

public final class ApiClient: ObservableObject, @unchecked Sendable {
    public static let shared = ApiClient()
    public init() {}
    var baseURL: String {
        #if targetEnvironment(simulator)
            return "http://localhost:8000/v1"
        #elseif DEBUG
            return "http://localhost:8000/v1"
        #else
            return "https://api.inline.chat/v1"
        #endif
    }

    private let decoder = JSONDecoder()

    private func request<T: Decodable>(_ path: Path, queryItems: [URLQueryItem] = [], includeToken: Bool = false) async throws -> T {
        guard var urlComponents = URLComponents(string: "\(baseURL)/\(path.rawValue)") else {
            throw APIError.invalidURL
        }

        urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = urlComponents.url else {
            throw APIError.invalidURL
        }

        print("url is \(url)")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let token = Auth.shared.getToken(), includeToken {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

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

    public func sendCode(email: String) async throws -> SendCodeResponse {
        try await request(.sendCode, queryItems: [URLQueryItem(name: "email", value: email)])
    }

    public func verifyCode(code: String, email: String) async throws -> VerifyCodeResponse {
        try await request(.verifyCode, queryItems: [URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email)])
    }

    public func createSpace(name: String) async throws -> CreateSpaceResult {
        try await request(.createSpace, queryItems: [URLQueryItem(name: "name", value: name)], includeToken: true)
    }
}

public struct VerifyCodeResponse: Codable, Sendable {
    public let ok: Bool
    public let userId: Int64
    public let token: String

    // Failed
    public let errorCode: Int?
    public let description: String?
}

public struct SendCodeResponse: Codable, Sendable {
    public let ok: Bool
    public let existingUser: Bool?

    // Failed
    public let errorCode: Int?
    public let description: String?
}

public struct CreateSpaceResult: Codable, Sendable {
    public let ok: Bool
    public let space: ApiSpace
}
