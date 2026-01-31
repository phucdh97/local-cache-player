//
//  AppDependencies.swift
//  VideoDemo
//
//  Composition Root - Single place where all dependencies are created and wired
//  This is the only place that knows the concrete types (Clean Architecture)
//

import Foundation
import UIKit

/// Composition Root: Centralized dependency injection container
/// Creates all dependencies once at app startup and wires them together
/// Benefits:
/// - Single source of truth for dependency configuration
/// - Easy to swap implementations (e.g., mocks for testing)
/// - Clear dependency graph in one place
/// - Separates object creation from business logic
class AppDependencies {
    
    // MARK: - Shared Instances (Created Once)
    
    /// Single cache storage instance for the entire app
    /// Uses CacheStorage protocol - can swap PINCache with another implementation
    let cacheStorage: CacheStorage
    
    /// Single cache query manager for UI operations
    /// Uses VideoCacheQuerying protocol - high-level code depends on abstraction
    let cacheQuery: VideoCacheQuerying
    
    /// Single player service instance
    /// Provides player creation with caching infrastructure
    let playerManager: VideoPlayerService
    
    // MARK: - Configuration
    
    private let storageConfig: CacheStorageConfiguration
    private let cachingConfig: CachingConfiguration
    
    // MARK: - Initialization
    
    /// Initialize app dependencies with configurations
    /// - Parameters:
    ///   - storageConfig: Cache storage configuration (memory/disk limits)
    ///   - cachingConfig: Caching behavior configuration (incremental thresholds)
    init(storageConfig: CacheStorageConfiguration = .default,
         cachingConfig: CachingConfiguration = .default) {
        
        self.storageConfig = storageConfig
        self.cachingConfig = cachingConfig
        
        // 1. Create the single cache storage (PINCache wrapper)
        self.cacheStorage = PINCacheAdapter(configuration: storageConfig)
        
        // 2. Create VideoCacheService with injected cache
        let cacheService = VideoCacheService(cache: cacheStorage)
        self.cacheQuery = cacheService  // Use as protocol
        
        // 3. Create VideoPlayerService with injected dependencies
        self.playerManager = VideoPlayerService(
            cachingConfig: cachingConfig,
            cacheQuery: cacheService,
            cache: cacheStorage
        )
        
        print("🏗️ AppDependencies initialized")
        print("   Storage: Memory=\(formatBytes(Int64(storageConfig.memoryCostLimit))), Disk=\(formatBytes(Int64(storageConfig.diskByteLimit)))")
        print("   Caching: \(cachingConfig.isIncrementalCachingEnabled ? "Incremental (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))))" : "Disabled")")
    }
    
    // MARK: - Factory Methods (Optional)
    
    /// Create dependencies with device-specific configuration
    /// - Returns: AppDependencies configured for the current device
    static func forCurrentDevice() -> AppDependencies {
        #if os(iOS)
        // Detect device type and choose appropriate storage config
        let idiom = UIDevice.current.userInterfaceIdiom
        let storageConfig: CacheStorageConfiguration
        
        switch idiom {
        case .pad:
            // iPad: More cache for better experience
            storageConfig = .highPerformance
        case .phone:
            // iPhone: Standard cache
            storageConfig = .default
        default:
            storageConfig = .default
        }
        
        return AppDependencies(
            storageConfig: storageConfig,
            cachingConfig: .default
        )
        #else
        return AppDependencies()
        #endif
    }
}
