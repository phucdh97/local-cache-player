//
//  CacheStorageConfiguration.swift
//  VideoDemo
//
//  Configuration for cache storage infrastructure (memory/disk limits)
//  Separate from CachingConfiguration which controls caching behavior/strategy
//

import Foundation

/// Configuration for cache storage infrastructure
/// Controls cache size limits and storage setup (infrastructure layer)
struct CacheStorageConfiguration {
    /// Memory cache size limit in bytes
    let memoryCostLimit: UInt
    
    /// Disk cache size limit in bytes
    let diskByteLimit: UInt
    
    /// Cache instance name/identifier
    let name: String
    
    // MARK: - Presets
    
    /// Default configuration for standard devices
    /// Memory: 20MB for fast access to recent chunks
    /// Disk: 500MB for persistent storage with LRU eviction
    static let `default` = CacheStorageConfiguration(
        memoryCostLimit: 20 * 1024 * 1024,   // 20MB
        diskByteLimit: 500 * 1024 * 1024,    // 500MB
        name: "VideoCache"
    )
    
    /// High-performance configuration for devices with more resources (e.g., iPad)
    /// Memory: 50MB for larger working set
    /// Disk: 1GB for more persistent content
    static let highPerformance = CacheStorageConfiguration(
        memoryCostLimit: 50 * 1024 * 1024,   // 50MB
        diskByteLimit: 1024 * 1024 * 1024,   // 1GB
        name: "VideoCache"
    )
    
    /// Low-memory configuration for constrained devices
    /// Memory: 10MB to minimize memory pressure
    /// Disk: 250MB to conserve storage
    static let lowMemory = CacheStorageConfiguration(
        memoryCostLimit: 10 * 1024 * 1024,   // 10MB
        diskByteLimit: 250 * 1024 * 1024,    // 250MB
        name: "VideoCache"
    )
    
    // MARK: - Initialization
    
    /// Create custom cache storage configuration
    /// - Parameters:
    ///   - memoryCostLimit: Maximum memory cache size in bytes
    ///   - diskByteLimit: Maximum disk cache size in bytes
    ///   - name: Cache instance identifier
    init(memoryCostLimit: UInt, diskByteLimit: UInt, name: String) {
        self.memoryCostLimit = memoryCostLimit
        self.diskByteLimit = diskByteLimit
        self.name = name
    }
}
