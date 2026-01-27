//
//  VideoCacheManager.swift
//  VideoDemo
//
//  High-level cache manager for UI queries
//  Refactored to use AssetDataManager protocol
//

import Foundation
import AVFoundation
import PINCache

/// High-level cache manager for UI-facing operations
/// Delegates actual caching to AssetDataManager implementations
class VideoCacheManager {
    static let shared = VideoCacheManager()
    
    private init() {
        print("📦 VideoCacheManager initialized")
    }
    
    // MARK: - Cache Key Generation
    
    func cacheKey(for url: URL) -> String {
        return url.lastPathComponent
    }
    
    // MARK: - UI-Facing Cache Queries (Synchronous for simple polling)
    
    /// Check if video is fully cached
    func isCached(url: URL) -> Bool {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url))
        
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
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url))
        
        guard let assetData = assetDataManager.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return 0.0
        }
        
        let cached = Int64(assetData.mediaData.count)
        let total = assetData.contentInformation.contentLength
        
        let percentage = (Double(cached) / Double(total)) * 100.0
        return min(percentage, 100.0) // Cap at 100%
    }
    
    /// Check if video is partially cached
    func isPartiallyCached(for url: URL) -> Bool {
        let percentage = getCachePercentage(for: url)
        return percentage > 0 && percentage < 100
    }
    
    /// Get size of cached data for a specific video
    func getCachedFileSize(for url: URL) -> Int64 {
        let assetDataManager = PINCacheAssetDataManager(cacheKey: cacheKey(for: url))
        
        guard let assetData = assetDataManager.retrieveAssetData() else {
            return 0
        }
        
        return Int64(assetData.mediaData.count)
    }
    
    // MARK: - Cache Management
    
    /// Get total size of all cached videos
    func getCacheSize() -> Int64 {
        // PINCache provides this automatically
        let totalBytes = PINCacheAssetDataManager.Cache.diskByteCount
        return Int64(totalBytes)
    }
    
    /// Clear all cached videos
    func clearCache() {
        PINCacheAssetDataManager.Cache.removeAllObjects()
        print("🗑️ Cache cleared")
    }
}
