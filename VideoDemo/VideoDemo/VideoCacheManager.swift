//
//  VideoCacheManager.swift
//  VideoDemo
//
//  High-level cache manager for UI queries
//  Refactored to use dependency injection (Clean Architecture)
//

import Foundation
import AVFoundation

/// High-level cache manager for UI-facing operations
/// Implements VideoCacheQuerying protocol for dependency injection
/// Delegates actual caching to AssetDataManager implementations
class VideoCacheManager: VideoCacheQuerying {
    
    /// Injected cache storage (dependency inversion)
    private let cache: CacheStorage
    
    /// Initialize with injected cache dependency
    /// - Parameter cache: Cache storage implementation (injected)
    init(cache: CacheStorage) {
        self.cache = cache
        print("📦 VideoCacheManager initialized")
    }
    
    // MARK: - Cache Key Generation
    
    func cacheKey(for url: URL) -> String {
        return url.lastPathComponent
    }
    
    // MARK: - VideoCacheQuerying Protocol Implementation
    
    /// Check if video is fully cached
    func isCached(url: URL) -> Bool {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return false
        }
        
        // Fully cached if mediaData size equals contentLength
        return assetData.mediaData.count >= assetData.contentInformation.contentLength
    }
    
    /// Get cache percentage for a video
    /// Called by UI timer every 2-3 seconds
    func getCachePercentage(for url: URL) -> Double {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return 0.0
        }
        
        // Sum all cached ranges for total cached bytes
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        let total = assetData.contentInformation.contentLength
        
        let percentage = (Double(totalCached) / Double(total)) * 100.0
        let cappedPercentage = min(percentage, 100.0)
        
        // Format bytes for readable output
        let cachedMB = Double(totalCached) / (1024 * 1024)
        let totalMB = Double(total) / (1024 * 1024)
        let rangeCount = assetData.cachedRanges.count
        
        print("📊 Cache: \(String(format: "%.2f", cachedMB))MB/\(String(format: "%.2f", totalMB))MB = \(String(format: "%.1f%%", cappedPercentage)) (\(rangeCount) range(s))")
        
        return cappedPercentage
    }
    
    /// Check if video is partially cached
    func isPartiallyCached(for url: URL) -> Bool {
        let percentage = getCachePercentage(for: url)
        return percentage > 0 && percentage < 100
    }
    
    /// Get size of cached data for a specific video (sum of all ranges)
    func getCachedFileSize(for url: URL) -> Int64 {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url), cache: cache)
        
        guard let assetData = assetDataManager.retrieveAssetData() else {
            return 0
        }
        
        return assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
    }
    
    /// Get description of cached ranges for debugging
    func getCachedRangesDescription(for url: URL) -> String {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url), cache: cache)
        let ranges = assetDataManager.getCachedRanges()
        
        guard !ranges.isEmpty else { return "No cached ranges" }
        
        let descriptions = ranges.sorted { $0.offset < $1.offset }.map { range in
            let startMB = Double(range.offset) / (1024 * 1024)
            let endMB = Double(range.offset + range.length) / (1024 * 1024)
            let sizeMB = Double(range.length) / (1024 * 1024)
            return String(format: "[%.2f-%.2f MB] (%.2f MB)",
                         startMB,
                         endMB,
                         sizeMB)
        }
        
        return descriptions.joined(separator: ", ")
    }
    
    // MARK: - Cache Management
    
    /// Get total size of all cached videos
    func getCacheSize() -> Int64 {
        return Int64(cache.diskByteCount)
    }
    
    /// Clear all cached videos
    func clearCache() {
        cache.removeAllObjects()
        print("🗑️ Cache cleared")
    }
}
