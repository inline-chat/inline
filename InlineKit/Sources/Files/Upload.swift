//import InlineKit
//
//#if canImport(AppKit)
//import AppKit
//#else
//import UIKit
//#endif
//
//public protocol FileUploading {
//  func upload(file: URL) async throws -> URL
//  func cancel()
//}
//
//public actor FileUploader {
//  private var uploadTasks: [UUID: UploadTask]
//  private var uploadQueue: AsyncQueue<UUID>
//  private var activeUploads: Set<UUID>
//  
//  public init(
//    configuration: Configuration,
//    networkClient: FileUploading
//  ) {
//    self.configuration = configuration
//    self.networkClient = networkClient
//    uploadTasks = [:]
//    tasks = []
//    activeUploads = []
//    
//    // Start the upload processor
//    Task {
//      await processUploads()
//    }
//  }
//
//  // MARK: - Public
//  
//  public func upload(file: URL) async {}
//  
//  public func enqueueUpload(fileURL: URL) async throws -> UploadTask {
//    try validateFile(at: fileURL)
//    
//    let task = UploadTask(
//      id: UUID(),
//      filename: fileURL.lastPathComponent,
//      fileURL: fileURL,
//      createdAt: Date(),
//      state: .idle
//    )
//    
//    uploadTasks[task.id] = task
//    tasks = Array(uploadTasks.values).sorted { $0.createdAt < $1.createdAt }
//    
//    await uploadQueue.enqueue(task.id)
//    return task
//  }
//  
//  public func cancelUpload(id: UUID) {
//    uploadTasks[id]?.state = .cancelled
//    activeUploads.remove(id)
//    tasks = Array(uploadTasks.values).sorted { $0.createdAt < $1.createdAt }
//  }
//  
//  public func cancelAllUploads() {
//    for (_, task) in uploadTasks {
//      cancelUpload(id: task.id)
//    }
//  }
//  
//  // MARK: - Process
//
//  // MARK: - Private Methods
//  
//  private func processUploads() async {
//    await withTaskGroup(of: Void.self) { group in
//      while !Task.isCancelled {
//        // Check if we can start new uploads
//        while activeUploads.count < configuration.maxConcurrentUploads {
//          guard let taskId = await uploadQueue.dequeue() else { break }
//          guard let task = uploadTasks[taskId],
//                task.state != .cancelled else { continue }
//          
//          activeUploads.insert(taskId)
//          group.addTask { [weak self] in
//            await self?.processUpload(taskId: taskId)
//          }
//        }
//        
//        try? await Task.sleep(for: .milliseconds(100))
//      }
//    }
//  }
//  
//  private func processUpload(taskId: UUID) async {
//    guard var task = uploadTasks[taskId] else { return }
//    
//    do {
//      task.state = .preparing
//      updateTask(task)
//      
//      let preparedFile = try await prepareFile(at: task.fileURL)
//      
//      task.state = .uploading(progress: 0)
//      updateTask(task)
//      
//      let uploadedFileURL = try await networkClient.upload(file: preparedFile)
//      
//      task.state = .completed(url: uploadedFileURL)
//      updateTask(task)
//    } catch {
//      task.state = .failed(error)
//      updateTask(task)
//    }
//    
//    activeUploads.remove(taskId)
//  }
//  
//  private func updateTask(_ task: UploadTask) {
//    uploadTasks[task.id] = task
//    tasks = Array(uploadTasks.values).sorted { $0.createdAt < $1.createdAt }
//  }
//
//  // MARK: - Image Handling
//  
//#if os(macOS)
//  public func prepareImage(image: NSImage) async throws -> URL {
//    state = .preparing
//    
//    guard let tiffData = image.tiffRepresentation,
//          let bitmap = NSBitmapImageRep(data: tiffData),
//          let imageData = bitmap.representation(using: .jpeg, properties: [:])
//    else {
//      throw UploadError.preparationFailed
//    }
//    
//    let tempURL = FileManager.default.temporaryDirectory
//      .appendingPathComponent(UUID().uuidString)
//      .appendingPathExtension("jpg")
//    
//    try imageData.write(to: tempURL)
//    return tempURL
//  }
//#else
//  public func prepareImage(image: UIImage) async throws -> URL {
//    state = .preparing
//    
//    guard let imageData = image.jpegData(compressionQuality: 0.8) else {
//      throw UploadError.preparationFailed
//    }
//    
//    let tempURL = FileManager.default.temporaryDirectory
//      .appendingPathComponent(UUID().uuidString)
//      .appendingPathExtension("jpg")
//    
//    try imageData.write(to: tempURL)
//    return tempURL
//  }
//#endif
//}
//
//// MARK: - AsyncQueue
//
//private actor AsyncQueue<T> {
//  private var items: [T] = []
//  private var continuations: [CheckedContinuation<T?, Never>] = []
//  
//  func enqueue(_ item: T) {
//    if let continuation = continuations.first {
//      continuations.removeFirst()
//      continuation.resume(returning: item)
//    } else {
//      items.append(item)
//    }
//  }
//  
//  func dequeue() async -> T? {
//    if let item = items.first {
//      items.removeFirst()
//      return item
//    }
//    
//    return await withCheckedContinuation { continuation in
//      continuations.append(continuation)
//    }
//  }
//}
//
//// MARK: - Upload State
//
//public enum UploadState: Equatable {
//  case idle
//  case preparing
//  case uploading(progress: Double)
//  case completed(url: URL)
//  case failed(Error)
//  case cancelled
//  
//  public static func == (lhs: UploadState, rhs: UploadState) -> Bool {
//    switch (lhs, rhs) {
//    case (.idle, .idle),
//         (.preparing, .preparing),
//         (.cancelled, .cancelled):
//      return true
//    case (.uploading(let lhsProgress), .uploading(let rhsProgress)):
//      return lhsProgress == rhsProgress
//    case (.completed(let lhsURL), .completed(let rhsURL)):
//      return lhsURL == rhsURL
//    case (.failed(let lhsError), .failed(let rhsError)):
//      return lhsError.localizedDescription == rhsError.localizedDescription
//    default:
//      return false
//    }
//  }
//}
