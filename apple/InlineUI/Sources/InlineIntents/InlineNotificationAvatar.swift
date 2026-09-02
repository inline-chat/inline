import Foundation

public enum InlineNotificationAvatar {
  public static let maximumBytes = 2 * 1_024 * 1_024

  public static func fallbackSource(
    hasProfilePhoto: Bool?, hasPhotoURL: Bool
  ) -> InlineMessageIntentDonation.UserAvatar.Source {
    hasProfilePhoto == false && !hasPhotoURL ? .noPhotoConfigured : .configuredPhotoUnavailable
  }

  /// Consume incrementally so an oversized response never becomes a complete Data buffer.
  public static func data(from url: URL, session: URLSession = .shared) async -> Data? {
    guard url.scheme?.lowercased() == "https", url.host != nil else { return nil }
    do {
      let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 2)
      let (bytes, response) = try await session.bytes(for: request)
      defer { bytes.task.cancel() }
      guard let response = response as? HTTPURLResponse,
            response.statusCode == 200,
            response.url?.scheme?.lowercased() == "https",
            response.expectedContentLength <= Int64(maximumBytes)
      else { return nil }

      return try await withTaskCancellationHandler {
        var data = Data()
        for try await byte in bytes {
          try Task.checkCancellation()
          guard data.count < maximumBytes else { return nil }
          data.append(byte)
        }
        return data
      } onCancel: {
        bytes.task.cancel()
      }
    } catch {
      // Artwork is optional; notification text must still be delivered.
      return nil
    }
  }
}
