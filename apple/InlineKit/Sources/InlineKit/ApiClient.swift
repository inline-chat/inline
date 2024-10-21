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
    case updateProfile
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

    public func sendCode(email: String) async throws -> APIResponse<SendCode> {
        try await request(.sendCode, queryItems: [URLQueryItem(name: "email", value: email)])
    }

    public func verifyCode(code: String, email: String) async throws -> APIResponse<VerifyCode> {
        try await request(.verifyCode, queryItems: [URLQueryItem(name: "code", value: code), URLQueryItem(name: "email", value: email)])
    }

    public func createSpace(name: String) async throws -> APIResponse<CreateSpace> {
        try await request(.createSpace, queryItems: [URLQueryItem(name: "name", value: name)], includeToken: true)
    }

    public func updateProfile(firstName: String, lastName: String, username: String) async throws -> APIResponse<UpdateProfile> {
        try await request(.updateProfile, queryItems: [URLQueryItem(name: "firstName", value: firstName), URLQueryItem(name: "lastName", value: lastName), URLQueryItem(name: "username", value: username)], includeToken: true)
    }
}

/// Example
/// {
///     "ok": true,
///     "result": {
///         "userId": 123,
///         "token": "123"
///     }
/// }
public enum APIResponse<T>: Decodable, Sendable where T: Codable & Sendable {
    case success(T)
    case error(errorCode: Int?, description: String?)

    private enum CodingKeys: String, CodingKey {
        case ok
        case errorCode
        case description
        case result
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if try values.decode(Bool.self, forKey: .ok) {
            self = try .success(values.decodeIfPresent(T.self, forKey: .result)!)
        } else {
            self = try .error(
                errorCode: values.decodeIfPresent(Int.self, forKey: .errorCode),
                description: values.decodeIfPresent(String.self, forKey: .description)
            )
        }
    }
}

public struct VerifyCode: Codable, Sendable {
    public let userId: Int64
    public let token: String
}

public struct SendCode: Codable, Sendable {
    public let existingUser: Bool?
}

public struct CreateSpace: Codable, Sendable {
    public let space: ApiSpace
    public let member: ApiMember
    public let chats: [ApiChat]
}

public struct UpdateProfile: Codable, Sendable {
    public let user: ApiUser
}
