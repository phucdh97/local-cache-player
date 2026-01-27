//
//  PINCacheAssetDataManager.swift
//  VideoDemo
//
//  PINCache-based implementation of AssetDataManager
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import PINCache

/// PINCache-based cache manager for video data
/// Suitable for small-medium videos (<100MB)
/// For large videos, consider FileHandleAssetDataManager instead
class PINCacheAssetDataManager: NSObject, AssetDataManager {
    
    /// Shared PINCache instance with configured limits
    /// Memory: 20MB for fast access to recent videos
    /// Disk: 500MB for persistent storage with LRU eviction
    static let Cache: PINCache = {
        let cache = PINCache(name: "ResourceLoader")
        
        // Configure memory cache: 20MB limit
        cache.memoryCache.costLimit = 20 * 1024 * 1024
        
        // Configure disk cache: 500MB limit with LRU eviction
        cache.diskCache.byteLimit = 500 * 1024 * 1024
        
        print("📦 PINCache initialized: Memory=20MB, Disk=500MB")
        return cache
    }()
    
    let cacheKey: String
    
    init(cacheKey: String) {
        self.cacheKey = cacheKey
        super.init()
    }
    
    // MARK: - AssetDataManager Protocol
    
    func retrieveAssetData() -> AssetData? {
        guard let assetData = PINCacheAssetDataManager.Cache.object(forKey: cacheKey) as? AssetData else {
            return nil
        }
        return assetData
    }
    
    func saveContentInformation(_ contentInformation: AssetDataContentInformation) {
        let assetData = AssetData()
        assetData.contentInformation = contentInformation
        
        // Async write to avoid blocking (PINCache handles thread safety)
        PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
    }
    
    func saveDownloadedData(_ data: Data, offset: Int) {
        guard let assetData = self.retrieveAssetData() else {
            return
        }
        
        // Merge new data with existing if continuous (sequential download)
        if let mediaData = self.mergeDownloadedDataIfIsContinuted(
            from: assetData.mediaData,
            with: data,
            offset: offset
        ) {
            assetData.mediaData = mediaData
            
            // Async write to avoid blocking
            PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
        }
    }
}
