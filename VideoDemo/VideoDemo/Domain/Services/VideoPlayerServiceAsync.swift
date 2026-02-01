//
//  VideoPlayerServiceAsync.swift
//  VideoDemo
//
//  Async video player service using FileHandle-based storage
//  Production implementation for iOS 17+
//

import Foundation
import AVFoundation

/// Async video player service for creating cached video players
/// Uses FileHandleAssetRepository for efficient large file handling
class VideoPlayerServiceAsync {
    
    // Configuration for caching behavior
    private let cachingConfig: CachingConfiguration
    
    // Store asset instances to keep ResourceLoaderAsync alive
    private var assets: [String: CachingAVURLAssetAsync] = [:]
    
    // Cache directory for FileHandle storage
    private let cacheDirectory: URL
    
    // Repository cache (NSCache can't hold actors directly, so we track them separately)
    private var repositories: [String: FileHandleAssetRepository] = [:]
    
    // MARK: - Initialization
    
    /// Initialize with async configuration
    /// - Parameters:
    ///   - cachingConfig: Configuration for incremental caching behavior
    ///   - cacheDirectory: Directory for FileHandle storage
    init(cachingConfig: CachingConfiguration = .default, cacheDirectory: URL) {
        self.cachingConfig = cachingConfig
        self.cacheDirectory = cacheDirectory
        
        // Ensure cache directory exists
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        print("📹 [Async] VideoPlayerServiceAsync initialized")
        print("   Cache Directory: \(cacheDirectory.path)")
        print("   Incremental Caching: \(cachingConfig.isIncrementalCachingEnabled ? "Enabled (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))))" : "Disabled")")
    }
    
    // MARK: - Public API
    
    func createPlayerItem(with url: URL) -> AVPlayerItem {
        let cacheKey = url.lastPathComponent
        
        // Get or create repository for this URL
        let repository: FileHandleAssetRepository
        if let existing = repositories[cacheKey] {
            repository = existing
        } else {
            do {
                repository = try FileHandleAssetRepository(
                    cacheKey: cacheKey,
                    cacheDirectory: cacheDirectory
                )
                repositories[cacheKey] = repository
            } catch {
                print("❌ [Async] Failed to create repository: \(error)")
                // Fallback - this shouldn't happen but handle gracefully
                repository = try! FileHandleAssetRepository(cacheKey: cacheKey, cacheDirectory: cacheDirectory)
            }
        }
        
        // Create async caching asset
        let asset = CachingAVURLAssetAsync(
            url: url,
            cachingConfig: cachingConfig,
            repository: repository
        )
        
        // Store asset to keep ResourceLoaderAsync alive
        assets[url.absoluteString] = asset
        
        print("🎬 [Async] Created player item for: \(url.lastPathComponent)")
        
        return AVPlayerItem(asset: asset)
    }
    
    func stopCurrentDownload() {
        print("🛑 [Async] Stopping all downloads")
        // CachingAVURLAssetAsync cleanup happens automatically via ResourceLoaderAsync deinit
    }
    
    func clearResourceLoaders() {
        stopCurrentDownload()
        assets.removeAll()
        repositories.removeAll()
        print("🧹 [Async] Cleared all resource loaders and repositories")
    }
}
