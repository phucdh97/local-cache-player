//
//  PINCacheAdapter.swift
//  VideoDemo
//
//  PINCache implementation of CacheStorage protocol (Infrastructure Layer)
//  This is the only place that depends on PINCache directly
//

import Foundation
import PINCache

/// Adapter that wraps PINCache to conform to CacheStorage protocol
/// Implements dependency inversion: high-level code depends on CacheStorage protocol,
/// not on this concrete implementation
final class PINCacheAdapter: CacheStorage {
    private let cache: PINCache
    private let configuration: CacheStorageConfiguration
    
    /// Initialize PINCache with configuration
    /// - Parameter configuration: Storage limits and cache name
    init(configuration: CacheStorageConfiguration = .default) {
        self.configuration = configuration
        self.cache = PINCache(name: configuration.name)
        
        // Configure memory cache limits
        self.cache.memoryCache.costLimit = configuration.memoryCostLimit
        
        // Configure disk cache limits with LRU eviction
        self.cache.diskCache.byteLimit = configuration.diskByteLimit
        
        print("📦 PINCacheAdapter initialized: Memory=\(formatBytes(Int64(configuration.memoryCostLimit))), Disk=\(formatBytes(Int64(configuration.diskByteLimit)))")
    }
    
    // MARK: - CacheStorage Protocol Implementation
    
    func object(forKey key: String) -> Any? {
        return cache.object(forKey: key)
    }
    
    func setObjectAsync(_ object: NSCoding, forKey key: String) {
        // PINCache's completion block signature: (PINCaching, String, Any?) -> Void
        // We don't need the completion for our use case, so pass nil
        cache.setObjectAsync(object, forKey: key, completion: nil)
    }
    
    var diskByteCount: UInt {
        return cache.diskCache.byteCount
    }
    
    func removeAllObjects() {
        cache.removeAllObjects()
    }
}
