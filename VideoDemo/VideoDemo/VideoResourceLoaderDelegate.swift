//
//  VideoResourceLoaderDelegate.swift
//  VideoDemo
//
//  Coordinates AVAssetResourceLoader requests using dictionary-based tracking
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher (ResourceLoader.swift)
//  Each request gets independent URLSession task for optimal seeking
//

import Foundation
import AVFoundation

class VideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    
    private let originalURL: URL
    
    // Serial queue for thread-safe coordination (like resourceLoaderDemo's loaderQueue)
    // Used by:
    // 1. AVAssetResourceLoader delegate callbacks (via setDelegate)
    // 2. Internal dictionary access (requests)
    // 3. VideoResourceLoaderRequest for URLSession callbacks
    let loaderQueue = DispatchQueue(label: "com.videocache.loader.queue", qos: .userInitiated)
    
    // Dictionary-based request tracking
    // Each AVAssetResourceLoadingRequest maps to its own VideoResourceLoaderRequest
    private var requests: [AVAssetResourceLoadingRequest: VideoResourceLoaderRequest] = [:]
    
    init(url: URL) {
        self.originalURL = url
        super.init()
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        let length = loadingRequest.dataRequest?.requestedLength ?? 0
        print("📥 New loading request: offset=\(offset), length=\(length)")
        
        // Note: This method is already called on loaderQueue (set via setDelegate)
        // No need for additional queue.async here - already synchronized!
        
        // Create dedicated request handler, pass loaderQueue for URLSession callbacks
        let request = VideoResourceLoaderRequest(
            originalURL: self.originalURL,
            loadingRequest: loadingRequest,
            loaderQueue: self.loaderQueue
        )
        
        // Cancel any existing request for this loading request
        self.requests[loadingRequest]?.cancel()
        
        // Store in dictionary and start
        self.requests[loadingRequest] = request
        request.start()
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        
        print("❌ Loading request cancelled")
        
        // Note: This method is already called on loaderQueue (set via setDelegate)
        // No need for additional queue.async - already synchronized!
        
        // Cancel and remove the specific request
        self.requests[loadingRequest]?.cancel()
        self.requests.removeValue(forKey: loadingRequest)
    }
    
    // MARK: - Download Control
    
    /// Stop all active downloads and cleanup resources
    /// Called when switching to another video
    func stopDownload() {
        loaderQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel all active requests
            for (_, request) in self.requests {
                request.cancel()
            }
            
            self.requests.removeAll()
            print("🛑 All requests stopped for \(self.originalURL.lastPathComponent)")
        }
    }
    
    deinit {
        stopDownload()
        print("♻️ VideoResourceLoaderDelegate deinitialized for \(originalURL.lastPathComponent)")
    }
}

