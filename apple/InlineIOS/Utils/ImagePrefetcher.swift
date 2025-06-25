import InlineKit
import InlineProtocol
import Logger
import Nuke
import NukeExtensions
import NukeUI
import Foundation


actor ImagePrefetcher {
    static let shared = ImagePrefetcher()
    
    // MARK: - Private Properties
    
    /// Active prefetch operations mapped by photo ID
    private var prefetchTasks: [Int64: Task<Void, Never>] = [:]
    
    /// Set of photo IDs that are already cached or being prefetched
    private var prefetchedPhotoIDs = Set<Int64>()
    
    /// Maximum number of concurrent prefetch operations
    private let maxConcurrentPrefetches = 15
    
    private let pipeline = ImagePipeline.shared
    
    private let prefetchQueue = DispatchQueue(
        label: "com.inline.imagePrefetcher",
        qos: .utility,
        attributes: .concurrent
    )
    
    // MARK: - Initialization
    
    private init() {
    }
    
    // MARK: - Public Methods
    
    /// Prefetch images for a collection of messages
    /// - Parameter messages: Array of messages that may contain images to prefetch
    func prefetchImages(for messages: [FullMessage]) async {
        let messagesToPrefetch = messages.filter { $0.photoInfo != nil }
        
        guard !messagesToPrefetch.isEmpty else { return }
        
        // Limit concurrent prefetches to avoid overwhelming resources
        let limitedMessages = Array(messagesToPrefetch.prefix(maxConcurrentPrefetches))
        
        #if DEBUG
        Log.shared.debug("Starting prefetch for \(limitedMessages.count) images on background thread")
        #endif
        
        for message in limitedMessages {
            await prefetchImage(for: message)
        }
    }
    
    func cancelAllPrefetching() async {
        for task in prefetchTasks.values {
            task.cancel()
        }
        prefetchTasks.removeAll()
        prefetchedPhotoIDs.removeAll()
        
        #if DEBUG
        Log.shared.debug("Cancelled all prefetching operations")
        #endif
    }
    
    /// Cancel prefetching for specific messages
    /// - Parameter messages: Array of messages to cancel prefetching for
    func cancelPrefetching(for messages: [FullMessage]) async {
        for message in messages {
            guard let photoInfo = message.photoInfo else { continue }
            
            let photoId = photoInfo.id
            
            if let task = prefetchTasks[photoId] {
                task.cancel()
                prefetchTasks.removeValue(forKey: photoId)
                prefetchedPhotoIDs.remove(photoId)
            }
        }
    }
    
    /// Clear all prefetch operations and cached state
    func clearCache() async {
        await cancelAllPrefetching()
        
        #if DEBUG
        Log.shared.debug("ImagePrefetcher cache cleared")
        #endif
    }
    
  
    // MARK: - Private Methods
    
    /// Prefetch a single image for a message
    /// - Parameter message: Message containing the image to prefetch
    private func prefetchImage(for message: FullMessage) async {
        guard let photoInfo = message.photoInfo else { return }
        
        let photoId = photoInfo.id
        
        // Skip if already being prefetched
        if prefetchedPhotoIDs.contains(photoId) || prefetchTasks[photoId] != nil {
            return
        }
        
        prefetchedPhotoIDs.insert(photoId)
        
        // First try local path
        if let photoSize = photoInfo.bestPhotoSize(), let localPath = photoSize.localPath {
            let localUrl = FileCache.getUrl(for: .photos, localPath: localPath)
            await prefetchLocalImage(url: localUrl, photoId: photoId)
        }
        // If not available locally, start downloading
        else {
            // Create a detached task to run on background thread
            let task = Task.detached(priority: .low) { [weak self] in
                guard let self = self else { return }
                
                do {
                    try await FileCache.shared.download(photo: photoInfo, for: message.message)
                    
                    if Task.isCancelled { return }
                    
                    // After download, prefetch the local image
                    if let photoSize = photoInfo.bestPhotoSize(), let localPath = photoSize.localPath {
                        let localUrl = FileCache.getUrl(for: .photos, localPath: localPath)
                        await self.prefetchLocalImage(url: localUrl, photoId: photoId)
                    }
                    
                    #if DEBUG
                    Log.shared.debug("Successfully downloaded and prefetched image for message \(message.id)")
                    #endif
                } catch {
                    // Handle errors silently for prefetching
                    if !Task.isCancelled {
                        #if DEBUG
                        Log.shared.error("Prefetch download failed: \(error.localizedDescription)")
                        #endif
                    }
                }
                
                // Clean up after completion
                await self.removePrefetchTask(for: photoId)
            }
            
            prefetchTasks[photoId] = task
        }
    }
    
    /// Prefetch a local image
    /// - Parameters:
    ///   - url: URL of the local image to prefetch
    ///   - photoId: ID of the photo being prefetched
    private func prefetchLocalImage(url: URL, photoId: Int64) async {
        let task = Task.detached(priority: .low) { [weak self] in
            guard let self = self else { return }
            
            let request = ImageRequest(
                url: url,
                processors: [.resize(width: 300)], // Resize to reasonable thumbnail size
                priority: .low,
                options: [.returnCacheDataDontLoad]
            )
            
            do {
                _ = try await self.pipeline.image(for: request)
                
                if Task.isCancelled { return }
                
                #if DEBUG
                Log.shared.debug("Successfully prefetched local image for photo ID: \(photoId)")
                #endif
            } catch {
                if !Task.isCancelled {
                    #if DEBUG
                    Log.shared.error("Local prefetch failed for photo ID \(photoId): \(error.localizedDescription)")
                    #endif
                }
            }
            
            // Clean up after completion
            await self.removePrefetchTask(for: photoId)
        }
        
        prefetchTasks[photoId] = task
    }
    
    /// Remove a prefetch task from tracking
    /// - Parameter photoId: ID of the photo whose task should be removed
    private func removePrefetchTask(for photoId: Int64) async {
        prefetchTasks.removeValue(forKey: photoId)
    }
    
    /// Prefetch images in batches to reduce the number of tasks
    /// - Parameters:
    ///   - messages: Array of messages to prefetch
    ///   - batchSize: Size of each batch
    func prefetchImagesInBatches(for messages: [FullMessage], batchSize: Int = 4) async {
        // Filter messages that need prefetching
        let messagesToPrefetch = messages.filter { message in
            guard let photoInfo = message.photoInfo else { return false }
            return !prefetchedPhotoIDs.contains(photoInfo.id) && prefetchTasks[photoInfo.id] == nil
        }
        
        guard !messagesToPrefetch.isEmpty else { return }
        
        // Process in batches
        for batchStart in stride(from: 0, to: messagesToPrefetch.count, by: batchSize) {
            let end = min(batchStart + batchSize, messagesToPrefetch.count)
            let batch = Array(messagesToPrefetch[batchStart..<end])
            
            // Create a single task for the batch
            let task = Task.detached(priority: .low) { [weak self] in
                guard let self = self else { return }
                
                for message in batch {
                    if Task.isCancelled { break }
                    
                    await self.prefetchImage(for: message)
                }
            }
            
            // Store task reference for each photo in the batch
            for message in batch {
                if let photoInfo = message.photoInfo {
                    prefetchTasks[photoInfo.id] = task
                    prefetchedPhotoIDs.insert(photoInfo.id)
                }
            }
        }
    }
    
    /// Check if a photo is already being prefetched
    /// - Parameter photoId: The photo ID to check
    /// - Returns: Boolean indicating if the photo is being prefetched
    func isBeingPrefetched(photoId: Int64) -> Bool {
        prefetchedPhotoIDs.contains(photoId) || prefetchTasks[photoId] != nil
    }
}
