//
//  CachedVideoPlayerManager.swift
//  VideoDemo
//
//  Manager for creating cached video players using ResourceLoader
//  Refactored to use CachingAVURLAsset and ResourceLoader
//

import Foundation
import AVFoundation

class CachedVideoPlayerManager {
    
    // Configuration for caching behavior
    private let cachingConfig: CachingConfiguration
    
    // Store ResourceLoader instances (via CachingAVURLAsset strong references)
    private var assets: [String: CachingAVURLAsset] = [:]
    private let cacheManager = VideoCacheManager.shared
    
    // MARK: - Initialization
    
    /// Initialize with caching configuration
    /// - Parameter cachingConfig: Configuration for incremental caching (default: .default)
    init(cachingConfig: CachingConfiguration = .default) {
        self.cachingConfig = cachingConfig
        print("📹 CachedVideoPlayerManager initialized with \(cachingConfig.isIncrementalCachingEnabled ? "incremental caching (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))) threshold)" : "original caching")")
    }
    
    // MARK: - Public API
    
    func createPlayerItem(with url: URL) -> AVPlayerItem {
        // Create CachingAVURLAsset with config which sets up ResourceLoader automatically
        let asset = CachingAVURLAsset(url: url, cachingConfig: self.cachingConfig)
        
        // Store asset to keep ResourceLoader alive
        assets[url.absoluteString] = asset
        
        if cacheManager.isCached(url: url) {
            print("🎬 Created player item for cached video: \(url.lastPathComponent)")
        } else {
            print("🎬 Created player item for: \(url.lastPathComponent)")
        }
        
        return AVPlayerItem(asset: asset)
    }
    
    func stopCurrentDownload() {
        // CachingAVURLAsset cleanup happens automatically via ResourceLoader deinit
        print("🛑 Stopping all downloads")
    }
    
    func clearResourceLoaders() {
        stopCurrentDownload()
        assets.removeAll()
        print("🧹 Cleared all resource loaders")
    }
}
