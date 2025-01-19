import Foundation

class NetworkUploadClient: FileUploading {
  private let session: URLSession
  private var currentTask: URLSessionUploadTask?
  
  public init(session: URLSession = .shared) {
    self.session = session
  }
  
  public func upload(file: URL) async throws -> URL {
    // Implement your actual upload logic here
    try await Task.sleep(for: .seconds(2)) // Simulated delay
    return URL(string: "https://example.com/uploaded/file.jpg")!
  }
  
  public func cancel() {
    currentTask?.cancel()
    currentTask = nil
  }
}
