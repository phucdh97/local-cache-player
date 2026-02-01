//
//  AppDependencies.swift
//  VideoDemo
//
//  Production composition root using async FileHandle-based storage
//  For legacy sync mode, see AppDependenciesLegacy.swift
//

import Foundation
import UIKit

/// Production composition root using async FileHandle storage
/// Clean async-only implementation for iOS 17+
/// For legacy sync mode, use AppDependenciesLegacy
class AppDependencies {
    
    // MARK: - Shared Instances
    
    /// Async cache query manager for UI operations
    let cacheQuery: VideoCacheQueryingAsync
    
    /// Async player service instance
    let playerManager: VideoPlayerServiceAsync
    
    /// Cache directory for FileHandle storage
    let cacheDirectory: URL
    
    // MARK: - Configuration
    
    private let storageConfig: CacheStorageConfiguration
    private let cachingConfig: CachingConfiguration
    
    // MARK: - Initialization
    
    /// Initialize production dependencies with async FileHandle storage
    /// - Parameters:
    ///   - storageConfig: Cache storage configuration (memory/disk limits)
    ///   - cachingConfig: Caching behavior configuration (incremental thresholds)
    ///   - cacheDirectory: Optional custom cache directory
    init(storageConfig: CacheStorageConfiguration = .default,
         cachingConfig: CachingConfiguration = .default,
         cacheDirectory: URL? = nil) {
        
        self.storageConfig = storageConfig
        self.cachingConfig = cachingConfig
        
        // Setup cache directory
        if let customDir = cacheDirectory {
            self.cacheDirectory = customDir
        } else {
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectory = cachesURL.appendingPathComponent("VideoCache")
        }
        
        // Create async cache service with FileHandle
        let cacheService = VideoCacheServiceAsync(cacheDirectory: self.cacheDirectory)
        self.cacheQuery = cacheService
        
        // Create async player service using FileHandle storage
        self.playerManager = VideoPlayerServiceAsync(
            cachingConfig: cachingConfig,
            cacheDirectory: self.cacheDirectory
        )
        
        print("🏗️ AppDependencies initialized (Production - Async FileHandle)")
        print("   Cache Directory: \(self.cacheDirectory.path)")
        print("   Storage: Memory=\(formatBytes(Int64(storageConfig.memoryCostLimit))), Disk=\(formatBytes(Int64(storageConfig.diskByteLimit)))")
        print("   Caching: \(cachingConfig.isIncrementalCachingEnabled ? "Incremental (\(formatBytes(Int64(cachingConfig.incrementalSaveThreshold))))" : "Disabled")")
        print("   ✅ Fully async: Video player and UI queries both use FileHandle storage")
    }
    
    // MARK: - Factory Methods
    
    /// Create dependencies for production use
    static func forProduction() -> AppDependencies {
        return AppDependencies(
            storageConfig: .default,
            cachingConfig: .default
        )
    }
    
    /// Create dependencies with device-specific configuration
    static func forCurrentDevice() -> AppDependencies {
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
        
        return AppDependencies(
            storageConfig: storageConfig,
            cachingConfig: .default
        )
        #else
        return AppDependencies()
        #endif
    }
}
