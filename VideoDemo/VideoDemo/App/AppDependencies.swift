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
/// Supports both sync (PINCache) and async (FileHandle) implementations
/// Benefits:
/// - Single source of truth for dependency configuration
/// - Easy to swap implementations (e.g., mocks for testing)
/// - Clear dependency graph in one place
/// - Separates object creation from business logic
class AppDependencies {
    
    // MARK: - Storage Mode
    
    enum StorageMode {
        case sync   // PINCache-based (demo/small videos)
        case async  // FileHandle-based (production/large videos)
    }
    
    // MARK: - Shared Instances (Created Once)
    
    /// Single cache storage instance for the entire app (sync mode)
    /// Uses CacheStorage protocol - can swap PINCache with another implementation
    let cacheStorage: CacheStorage?
    
    /// Single cache query manager for UI operations (sync mode)
    /// Uses VideoCacheQuerying protocol - high-level code depends on abstraction
    let cacheQuery: VideoCacheQuerying?
    
    /// Async cache query manager for production use (async mode)
    /// Uses async/await with FileHandle storage
    @available(iOS 13.0, *)
    var cacheQueryAsync: VideoCacheQueryingAsync? {
        return _cacheQueryAsync
    }
    private var _cacheQueryAsync: Any?
    
    /// Single player service instance
    /// Provides player creation with caching infrastructure
    let playerManager: VideoPlayerService
    
    /// Storage mode (sync or async)
    let storageMode: StorageMode
    
    // MARK: - Configuration
    
    private let storageConfig: CacheStorageConfiguration
    private let cachingConfig: CachingConfiguration
    
    // MARK: - Initialization
    
    /// Initialize app dependencies with configurations
    /// - Parameters:
    ///   - storageMode: Storage implementation to use (sync PINCache or async FileHandle)
    ///   - storageConfig: Cache storage configuration (memory/disk limits)
    ///   - cachingConfig: Caching behavior configuration (incremental thresholds)
    init(storageMode: StorageMode = .sync,
         storageConfig: CacheStorageConfiguration = .default,
         cachingConfig: CachingConfiguration = .default) {
        
        self.storageMode = storageMode
        self.storageConfig = storageConfig
        self.cachingConfig = cachingConfig
        
        switch storageMode {
        case .sync:
            // SYNC MODE: PINCache-based (demo/small videos)
            // 1. Create the single cache storage (PINCache wrapper)
            self.cacheStorage = PINCacheAdapter(configuration: storageConfig)
            
            // 2. Create VideoCacheService with injected cache
            let cacheService = VideoCacheService(cache: self.cacheStorage!)
            self.cacheQuery = cacheService
            self._cacheQueryAsync = nil
            
            // 3. Create VideoPlayerService with injected cache
            self.playerManager = VideoPlayerService(
                cachingConfig: cachingConfig,
                cache: self.cacheStorage!
            )
            
            print("🏗️ AppDependencies initialized (SYNC mode - PINCache)")
            
        case .async:
            // ASYNC MODE: FileHandle-based (production/large videos)
            self.cacheStorage = nil
            self.cacheQuery = nil
            
            if #available(iOS 13.0, *) {
                // 1. Create async cache service with FileHandle
                let asyncCacheService = VideoCacheServiceAsync()
                self._cacheQueryAsync = asyncCacheService
                
                // 2. Create VideoPlayerService (will use async internally)
                // Note: For now, using PINCache as fallback. Will update VideoPlayerService to support async mode.
                let fallbackStorage = PINCacheAdapter(configuration: storageConfig)
                self.playerManager = VideoPlayerService(
                    cachingConfig: cachingConfig,
                    cache: fallbackStorage
                )
                
                print("🏗️ AppDependencies initialized (ASYNC mode - FileHandle)")
            } else {
                // Fallback to sync mode for older iOS versions
                fatalError("Async mode requires iOS 13.0+")
            }
        }
        
        print("   Storage: Memory=\(formatBytes(Int64(storageConfig.memoryCostLimit))), Disk=\(formatBytes(Int64(storageConfig.diskByteLimit)))")
        print("   Caching: \(cachingConfig.isIncrementalCachingEnabled ? "Incremental (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))))" : "Disabled")")
    }
    
    // MARK: - Factory Methods (Optional)
    
    /// Create dependencies for production use with async FileHandle storage
    /// - Returns: AppDependencies configured for production (async mode)
    @available(iOS 13.0, *)
    static func forProduction() -> AppDependencies {
        return AppDependencies(
            storageMode: .async,
            storageConfig: .default,
            cachingConfig: .default
        )
    }
    
    /// Create dependencies for demo/testing with sync PINCache storage
    /// - Returns: AppDependencies configured for demo (sync mode)
    static func forDemo() -> AppDependencies {
        return AppDependencies(
            storageMode: .sync,
            storageConfig: .default,
            cachingConfig: .default
        )
    }
    
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
        
        // Use async mode for production
        if #available(iOS 13.0, *) {
            return AppDependencies(
                storageMode: .async,
                storageConfig: storageConfig,
                cachingConfig: .default
            )
        } else {
            // Fallback to sync for older iOS
            return AppDependencies(
                storageMode: .sync,
                storageConfig: storageConfig,
                cachingConfig: .default
            )
        }
        #else
        return AppDependencies()
        #endif
    }
}
