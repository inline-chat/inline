import Auth
import Combine
import Foundation
import InlineConfig
import Logger
import MultipartFormDataKit
import UIKit

public enum APIError: Error {
  case invalidURL
  case invalidResponse
  case httpError(statusCode: Int)
  case decodingError(Error)
  case networkError
  case rateLimited
  case error(error: String, errorCode: Int?, description: String?)
}

public enum Path: String {
  case sendMessage20250509
}

public final class SharedApiClient: ObservableObject, @unchecked Sendable {
  public static let shared = SharedApiClient()
  public init() {}

  private let log = Log.scoped("ApiClient")

  public static let baseURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat/v1"
    }

    #if targetEnvironment(simulator)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #elseif DEBUG && os(iOS)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #elseif DEBUG && os(macOS)
    return "http://\(ProjectConfig.devHost):8000/v1"
    #else
    return "https://api.inline.chat/v1"
    #endif
  }()

  public var baseURL: String { Self.baseURL }

  private let decoder = JSONDecoder()

  private func request<T: Decodable & Sendable>(
    _ path: Path,
    queryItems: [URLQueryItem] = [],
    includeToken: Bool = false
  ) async throws -> T {
    guard var urlComponents = URLComponents(string: "\(baseURL)/\(path.rawValue)") else {
      throw APIError.invalidURL
    }

    urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = urlComponents.url else {
      throw APIError.invalidURL
    }

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
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("API error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
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

  private func postRequest<T: Decodable & Sendable>(
    _ path: Path,
    body: [String: Any],
    includeToken: Bool = true
  ) async throws -> T {
    guard let url = URL(string: "\(baseURL)/\(path.rawValue)") else {
      throw APIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let token = Auth.shared.getToken(), includeToken {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)

      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("API error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
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

  public func sendMessage(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    text: String?,
    photoId: Int64? = nil,
    documentId: Int64? = nil
  ) async throws -> EmptyPayload {
    var body: [String: Any] = [:]
    
    if let text {
      body["text"] = text
    }

    if let peerUserId {
      body["peerUserId"] = peerUserId
    }

    if let peerThreadId {
      body["peerThreadId"] = peerThreadId
    }

    if let photoId {
      body["photoId"] = photoId
    }
    
    if let documentId {
      body["documentId"] = documentId
    }

    return try await postRequest(
      .sendMessage20250509,
      body: body,
      includeToken: true
    )
  }

  public enum FileType: String, Codable, Sendable {
    case photo
    case document
  }

  public func uploadFile(
    type: FileType = .photo,
    data: Data,
    filename: String,
    mimeType: MIMEType,
    progress: @escaping (Double) -> Void
  ) async throws -> UploadFileResult {
    guard let url = URL(string: "\(baseURL)/uploadFile") else {
      throw APIError.invalidURL
    }
    let multipartFormData = try MultipartFormData.Builder.build(
      with: [
        (
          name: "type",
          filename: nil,
          mimeType: nil,
          data: type.rawValue.data(using: .utf8)!
        ),
        (
          name: "file",
          filename: filename,
          mimeType: mimeType,
          data: data
        ),
      ],
      willSeparateBy: RandomBoundaryGenerator.generate()
    )

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(multipartFormData.contentType, forHTTPHeaderField: "Content-Type")
    request.httpBody = multipartFormData.body

    if let token = Auth.shared.getToken() {
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.invalidResponse
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          let apiResponse = try decoder.decode(APIResponse<UploadFileResult>.self, from: data)
          switch apiResponse {
            case let .success(data):
              return data
            case let .error(error, errorCode, description):
              log.error("Upload error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
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
}

/// Example
/// {
///     "ok": true,
///     "result": {
///         "userId": 123,
///         "token": "123"
///     }
/// }
public enum APIResponse<T>: Decodable, Sendable where T: Decodable & Sendable {
  case success(T)
  case error(error: String, errorCode: Int?, description: String?)

  private enum CodingKeys: String, CodingKey {
    case ok
    case result
    case error
    case errorCode
    case description
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if try values.decode(Bool.self, forKey: .ok) {
      if T.self == EmptyPayload.self {
        self = .success(EmptyPayload() as! T)
      } else {
        self = try .success(values.decode(T.self, forKey: .result))
      }
    } else {
      let error = try values.decodeIfPresent(String.self, forKey: .error) ?? "Unknown error"
      let errorCode = try values.decodeIfPresent(Int.self, forKey: .errorCode)
      let description = try values.decodeIfPresent(String.self, forKey: .description)
      self = .error(error: error, errorCode: errorCode, description: description)
    }
  }
}

public struct EmptyPayload: Codable, Sendable {}

public struct UploadFileResult: Codable, Sendable {
  public let fileUniqueId: String
  public let photoId: Int64?
  public let videoId: Int64?
  public let documentId: Int64?
}
