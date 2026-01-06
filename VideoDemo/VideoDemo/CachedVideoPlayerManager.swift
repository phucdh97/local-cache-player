//
//  CachedVideoPlayerManager.swift
//  VideoDemo
//
//  Manager for creating cached video players
//

import Foundation
import AVFoundation

class CachedVideoPlayerManager {
    
    private var resourceLoaderDelegates: [String: VideoResourceLoaderDelegate] = [:]
    private let cacheManager = VideoCacheManager.shared
    
    // MARK: - Public API
    
    func createPlayerItem(with url: URL) -> AVPlayerItem {
        // Always use custom URL with resource loader, even for cached videos
        // This ensures proper handling of cached data
        
        // Create custom URL with special scheme
        guard let customURL = createCustomURL(from: url) else {
            print("❌ Failed to create custom URL, using original")
            return AVPlayerItem(url: url)
        }
        
        // Create asset with custom scheme
        let asset = AVURLAsset(url: customURL)
        
        // Create and set resource loader delegate
        let delegate = VideoResourceLoaderDelegate(url: url)
        resourceLoaderDelegates[customURL.absoluteString] = delegate
        
        asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue.main)
        
        if cacheManager.isCached(url: url) {
            print("🎬 Created player item for cached video: \(url.lastPathComponent)")
        } else {
            print("🎬 Created player item for: \(url.lastPathComponent)")
        }
        
        return AVPlayerItem(asset: asset)
    }
    
    func stopCurrentDownload() {
        // Stop all active downloads managed by this instance
        for (_, delegate) in resourceLoaderDelegates {
            delegate.stopDownload()
        }
    }
    
    func clearResourceLoaders() {
        stopCurrentDownload()
        resourceLoaderDelegates.removeAll()
        print("🧹 Cleared all resource loaders")
    }
    
    // MARK: - Private Helpers
    
    private func createCustomURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        
        // Replace scheme with custom scheme
        // We use "cachevideo" as custom scheme
        components.scheme = "cachevideo"
        
        return components.url
    }
}

