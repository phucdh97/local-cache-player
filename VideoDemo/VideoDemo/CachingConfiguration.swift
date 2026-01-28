//
//  CachingConfiguration.swift
//  VideoDemo
//
//  Configuration for video caching behavior using dependency injection
//

import Foundation

/// Configuration for video caching behavior
/// Immutable struct (value type) passed via dependency injection
struct CachingConfiguration {
    /// Threshold for incremental chunk saves (in bytes)
    let incrementalSaveThreshold: Int
    
    /// Whether incremental caching is enabled
    let isIncrementalCachingEnabled: Bool
    
    // MARK: - Presets
    
    /// Default configuration (recommended)
    /// 512 KB threshold balances data loss prevention with disk I/O
    static let `default` = CachingConfiguration(
        incrementalSaveThreshold: 512 * 1024,
        isIncrementalCachingEnabled: true
    )
    
    /// Conservative configuration
    /// 1 MB threshold minimizes disk I/O, but higher data loss risk
    static let conservative = CachingConfiguration(
        incrementalSaveThreshold: 1024 * 1024,
        isIncrementalCachingEnabled: true
    )
    
    /// Aggressive configuration
    /// 256 KB threshold minimizes data loss, but more disk I/O
    static let aggressive = CachingConfiguration(
        incrementalSaveThreshold: 256 * 1024,
        isIncrementalCachingEnabled: true
    )
    
    /// Disabled configuration (original behavior)
    /// Only saves on request completion, maximum data loss on force-quit
    static let disabled = CachingConfiguration(
        incrementalSaveThreshold: 512 * 1024,
        isIncrementalCachingEnabled: false
    )
    
    // MARK: - Initialization
    
    /// Create custom configuration
    /// - Parameters:
    ///   - incrementalSaveThreshold: Bytes to accumulate before saving (min 256KB)
    ///   - isIncrementalCachingEnabled: Enable/disable incremental caching
    init(incrementalSaveThreshold: Int, isIncrementalCachingEnabled: Bool) {
        self.incrementalSaveThreshold = max(256 * 1024, incrementalSaveThreshold)
        self.isIncrementalCachingEnabled = isIncrementalCachingEnabled
    }
}
