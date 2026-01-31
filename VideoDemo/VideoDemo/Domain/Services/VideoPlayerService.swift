//
//  VideoPlayerService.swift
//  VideoDemo
//
//  Service for creating cached video players using ResourceLoader
//  Refactored to use CachingAVURLAsset and ResourceLoader
//

import Foundation
import AVFoundation

/// Video player service for creating cached video players
/// Coordinates player creation with caching infrastructure
/// Service pattern: provides player creation and coordination
class VideoPlayerService {
    
    // Configuration for caching behavior
    private let cachingConfig: CachingConfiguration
    
    // Store ResourceLoader instances (via CachingAVURLAsset strong references)
    private var assets: [String: CachingAVURLAsset] = [:]
    
    // Injected dependencies (Clean Architecture)
    private let cacheQuery: VideoCacheQuerying  // For isCached checks
    private let cache: CacheStorage            // For creating assets
    
    // MARK: - Initialization
    
    /// Initialize with dependency injection
    /// - Parameters:
    ///   - cachingConfig: Configuration for incremental caching behavior
    ///   - cacheQuery: Cache query interface for checking cache status
    ///   - cache: Cache storage for asset creation
    init(cachingConfig: CachingConfiguration = .default, 
         cacheQuery: VideoCacheQuerying,
         cache: CacheStorage) {
        self.cachingConfig = cachingConfig
        self.cacheQuery = cacheQuery
        self.cache = cache
        print("📹 VideoPlayerService initialized with \(cachingConfig.isIncrementalCachingEnabled ? "incremental caching (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))) threshold)" : "original caching")")
    }
    
    // MARK: - Public API
    
    func createPlayerItem(with url: URL) -> AVPlayerItem {
        // Create CachingAVURLAsset with config and injected cache
        let asset = CachingAVURLAsset(url: url, cachingConfig: self.cachingConfig, cache: cache)
        
        // Store asset to keep ResourceLoader alive
        assets[url.absoluteString] = asset
        
        if cacheQuery.isCached(url: url) {
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
