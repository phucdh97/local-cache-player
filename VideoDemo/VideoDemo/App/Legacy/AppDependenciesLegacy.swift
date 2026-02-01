//
//  AppDependenciesLegacy.swift
//  VideoDemo
//
//  Legacy sync dependency injection container
//  For testing and comparison with async implementation
//

import Foundation
import UIKit

/// Legacy composition root using sync PINCache-based storage
/// Kept functional for testing and comparison purposes
class AppDependenciesLegacy {
    
    // MARK: - Shared Instances (Non-optional, sync only)
    
    /// Cache storage using PINCache
    let cacheStorage: CacheStorage
    
    /// Cache query manager for UI operations
    let cacheQuery: VideoCacheQuerying
    
    /// Player service instance
    let playerManager: VideoPlayerService
    
    // MARK: - Configuration
    
    private let storageConfig: CacheStorageConfiguration
    private let cachingConfig: CachingConfiguration
    
    // MARK: - Initialization
    
    /// Initialize legacy dependencies with PINCache-based storage
    init(storageConfig: CacheStorageConfiguration = .default,
         cachingConfig: CachingConfiguration = .default) {
        
        self.storageConfig = storageConfig
        self.cachingConfig = cachingConfig
        
        // Create PINCache storage
        self.cacheStorage = PINCacheAdapter(configuration: storageConfig)
        
        // Create legacy cache service
        let cacheService = VideoCacheServiceLegacy(cache: cacheStorage)
        self.cacheQuery = cacheService
        
        // Create player service
        self.playerManager = VideoPlayerService(
            cachingConfig: cachingConfig,
            cache: cacheStorage
        )
        
        print("🏗️ [Legacy] AppDependenciesLegacy initialized (PINCache)")
        print("   Storage: Memory=\(formatBytes(Int64(storageConfig.memoryCostLimit))), Disk=\(formatBytes(Int64(storageConfig.diskByteLimit)))")
        print("   Caching: \(cachingConfig.isIncrementalCachingEnabled ? "Incremental (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))))" : "Disabled")")
    }
    
    // MARK: - Factory Methods
    
    /// Create legacy dependencies for testing
    static func forDemo() -> AppDependenciesLegacy {
        return AppDependenciesLegacy()
    }
    
    /// Create legacy dependencies with device-specific configuration
    static func forCurrentDevice() -> AppDependenciesLegacy {
        #if os(iOS)
        let idiom = UIDevice.current.userInterfaceIdiom
        let storageConfig: CacheStorageConfiguration
        
        switch idiom {
        case .pad:
            storageConfig = .highPerformance
        case .phone:
            storageConfig = .default
        default:
            storageConfig = .default
        }
        
        return AppDependenciesLegacy(
            storageConfig: storageConfig,
            cachingConfig: .default
        )
        #else
        return AppDependenciesLegacy()
        #endif
    }
}
