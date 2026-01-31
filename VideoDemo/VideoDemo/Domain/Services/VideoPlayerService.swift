//
//  VideoPlayerService.swift
//  VideoDemo
//
//  Service for creating cached video players using ResourceLoader
//  Single Responsibility: Creates and manages AVPlayerItem instances with caching
//

import Foundation
import AVFoundation

/// Video player service for creating cached video players
/// Single Responsibility: Creates AVPlayerItem with caching infrastructure
/// Does NOT check cache status - that's the ViewModel's job
class VideoPlayerService {

    // Configuration for caching behavior
    private let cachingConfig: CachingConfiguration

    // Store ResourceLoader instances (via CachingAVURLAsset strong references)
    private var assets: [String: CachingAVURLAsset] = [:]

    // Injected dependency (Clean Architecture)
    private let cache: CacheStorage

    // MARK: - Initialization

    /// Initialize with dependency injection
    /// - Parameters:
    ///   - cachingConfig: Configuration for incremental caching behavior
    ///   - cache: Cache storage for asset creation
    init(cachingConfig: CachingConfiguration = .default, cache: CacheStorage) {
        self.cachingConfig = cachingConfig
        self.cache = cache
        print("📹 VideoPlayerService initialized with \(cachingConfig.isIncrementalCachingEnabled ? "incremental caching (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))) threshold)" : "original caching")")
    }

    // MARK: - Public API

    func createPlayerItem(with url: URL) -> AVPlayerItem {
        // Create CachingAVURLAsset with config and injected cache
        let asset = CachingAVURLAsset(url: url, cachingConfig: self.cachingConfig, cache: cache)

        // Store asset to keep ResourceLoader alive
        assets[url.absoluteString] = asset

        print("🎬 Created player item for: \(url.lastPathComponent)")

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
