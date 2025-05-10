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
  public init() {
    print("SharedApiClient initialized")
  }

  private let log = Log.scoped("ApiClient")

  public static let baseURL: String = {
    if ProjectConfig.useProductionApi {
      return "https://api.inline.chat/v1"
    }

    #if targetEnvironment(simulator)
    return "http://172.20.10.6:8000/v1"
    #elseif DEBUG && os(iOS)
    return "http://172.20.10.6:8000/v1"
    #elseif DEBUG && os(macOS)
    return "http://172.20.10.6:8000/v1"
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
    print("Making request to path: \(path.rawValue)")
    guard var urlComponents = URLComponents(string: "\(baseURL)/\(path.rawValue)") else {
      print("Failed to create URL components")
      throw APIError.invalidURL
    }

    urlComponents.queryItems = queryItems.isEmpty ? nil : queryItems

    guard let url = urlComponents.url else {
      print("Failed to create URL from components")
      throw APIError.invalidURL
    }

    print("Request URL: \(url)")
    var request = URLRequest(url: url)
    request.httpMethod = "GET"

    if let token = Auth.shared.getToken(), includeToken {
      print("Adding authorization token")
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      print("Sending request...")
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("Invalid response type")
        throw APIError.invalidResponse
      }

      print("Received response with status code: \(httpResponse.statusCode)")
      switch httpResponse.statusCode {
        case 200 ... 299:
          print("Request successful, decoding response")
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              print("Successfully decoded response")
              return data
            case let .error(error, errorCode, description):
              print("API returned error: \(error) (\(errorCode ?? 0)): \(description ?? "")")
              log.error("Error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          print("Rate limited")
          throw APIError.rateLimited
        default:
          print("HTTP error: \(httpResponse.statusCode)")
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      print("Decoding error: \(decodingError)")
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      print("API error: \(apiError)")
      throw apiError
    } catch {
      print("Network error: \(error)")
      throw APIError.networkError
    }
  }

  private func postRequest<T: Decodable & Sendable>(
    _ path: Path,
    body: [String: Any],
    includeToken: Bool = true
  ) async throws -> T {
    print("Making POST request to path: \(path.rawValue)")
    guard let url = URL(string: "\(baseURL)/\(path.rawValue)") else {
      print("Failed to create URL")
      throw APIError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let token = Auth.shared.getToken(), includeToken {
      print("Adding authorization token")
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      print("Encoding request body")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      print("Request body: \(String(data: request.httpBody!, encoding: .utf8) ?? "")")

      print("Sending POST request...")
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("Invalid response type")
        throw APIError.invalidResponse
      }

      print("Received response with status code: \(httpResponse.statusCode)")
      switch httpResponse.statusCode {
        case 200 ... 299:
          print("Request successful, decoding response")
          let apiResponse = try decoder.decode(APIResponse<T>.self, from: data)
          switch apiResponse {
            case let .success(data):
              print("Successfully decoded response")
              return data
            case let .error(error, errorCode, description):
              print("API returned error: \(error) (\(errorCode ?? 0)): \(description ?? "")")
              log.error("Error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          print("Rate limited")
          throw APIError.rateLimited
        default:
          print("HTTP error: \(httpResponse.statusCode)")
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      print("Decoding error: \(decodingError)")
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      print("API error: \(apiError)")
      throw apiError
    } catch {
      print("Network error: \(error)")
      throw APIError.networkError
    }
  }

  public func sendMessage(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    text: String?,
    randomId: Int64?,
    repliedToMessageId: Int64?,
    date: Double?,
    fileUniqueId: String? = nil,
    isSticker: Bool? = nil
  ) async throws -> EmptyPayload {
    print("Preparing to send message")
    var body: [String: Any] = [
      "text": text as Any,
    ]

    if let peerUserId {
      body["peerUserId"] = peerUserId
    }

    if let peerThreadId {
      body["peerThreadId"] = peerThreadId
    }

    if let randomId {
      body["randomId"] = "\(randomId)"
    }

    if let repliedToMessageId {
      body["replyToMessageId"] = repliedToMessageId
    }

    if let fileUniqueId {
      body["fileUniqueId"] = fileUniqueId
    }

    if let isSticker {
      body["isSticker"] = isSticker
    }

    print("Message body prepared: \(body)")
    return try await postRequest(
      .sendMessage20250509,
      body: body,
      includeToken: true
    )
  }

  public enum FileType: String, Codable, Sendable {
    case photo
  }

  public func uploadFile(
    type: FileType = .photo,
    data: Data,
    filename: String,
    mimeType: MIMEType,
    progress: @escaping (Double) -> Void
  ) async throws -> UploadFileResult {
    print("Preparing to upload file: \(filename) of type \(type.rawValue)")
    guard let url = URL(string: "\(baseURL)/uploadFile") else {
      print("Failed to create upload URL")
      throw APIError.invalidURL
    }

    print("Creating multipart form data")
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
      print("Adding authorization token")
      request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    } else {
      print("Warning: No authorization token available")
    }

    do {
      print("Sending file upload request...")
      let (data, response) = try await URLSession.shared.data(for: request)

      guard let httpResponse = response as? HTTPURLResponse else {
        print("Invalid response type")
        throw APIError.invalidResponse
      }

      print("Received response with status code: \(httpResponse.statusCode)")

      // Print response body for debugging
      if let responseString = String(data: data, encoding: .utf8) {
        print("Response body: \(responseString)")
      }

      switch httpResponse.statusCode {
        case 200 ... 299:
          print("Upload successful, decoding response")
          let apiResponse = try decoder.decode(APIResponse<UploadFileResult>.self, from: data)
          switch apiResponse {
            case let .success(data):
              print("Successfully decoded upload response")
              return data
            case let .error(error, errorCode, description):
              print("API returned error: \(error) (\(errorCode ?? 0)): \(description ?? "")")
              log.error("Error \(error): \(description ?? "")")
              throw APIError.error(error: error, errorCode: errorCode, description: description)
          }
        case 429:
          print("Rate limited")
          throw APIError.rateLimited
        default:
          print("HTTP error: \(httpResponse.statusCode)")
          if let responseString = String(data: data, encoding: .utf8) {
            print("Error response body: \(responseString)")
          }
          throw APIError.httpError(statusCode: httpResponse.statusCode)
      }
    } catch let decodingError as DecodingError {
      print("Decoding error: \(decodingError)")
      throw APIError.decodingError(decodingError)
    } catch let apiError as APIError {
      print("API error: \(apiError)")
      throw apiError
    } catch {
      print("Network error: \(error)")
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
