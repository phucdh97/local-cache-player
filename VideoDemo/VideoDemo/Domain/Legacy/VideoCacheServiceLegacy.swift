//
//  VideoCacheServiceLegacy.swift
//  VideoDemo
//
//  Legacy sync implementation using PINCache
//  For testing and comparison purposes
//

import Foundation
import AVFoundation

/// High-level cache service for UI-facing operations (Legacy sync version)
/// Implements VideoCacheQuerying protocol for dependency injection
/// Uses synchronous PINCache operations with background queue wrapping for UI
class VideoCacheServiceLegacy: VideoCacheQuerying {
    
    /// Injected cache storage (dependency inversion)
    private let cache: CacheStorage
    
    /// Initialize with injected cache dependency
    /// - Parameter cache: Cache storage implementation (injected)
    init(cache: CacheStorage) {
        self.cache = cache
        print("📦 [Legacy] VideoCacheServiceLegacy initialized")
    }
    
    // MARK: - Cache Key Generation
    
    func cacheKey(for url: URL) -> String {
        return url.lastPathComponent
    }
    
    // MARK: - VideoCacheQuerying Protocol Implementation
    
    /// Check if video is fully cached
    func isCached(url: URL) -> Bool {
        let assetDataManager = VideoAssetRepository(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return false
        }
        
        // Fully cached if sum of cached ranges equals contentLength
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        return totalCached >= assetData.contentInformation.contentLength
    }
    
    /// Get cache percentage for a video
    func getCachePercentage(for url: URL) -> Double {
        let assetDataManager = VideoAssetRepository(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return 0.0
        }
        
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        let total = assetData.contentInformation.contentLength
        
        let percentage = (Double(totalCached) / Double(total)) * 100.0
        return min(percentage, 100.0)
    }
    
    /// Get size of cached data for a specific video
    func getCachedFileSize(for url: URL) -> Int64 {
        let assetDataManager = VideoAssetRepository(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData() else {
            return 0
        }
        
        return assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
    }
    
    // MARK: - Cache Management
    
    /// Get total size of all cached videos
    func getCacheSize() -> Int64 {
        return Int64(cache.diskByteCount)
    }
    
    /// Clear all cached videos
    func clearCache() {
        cache.removeAllObjects()
        print("🗑️ [Legacy] Cache cleared")
    }
}
