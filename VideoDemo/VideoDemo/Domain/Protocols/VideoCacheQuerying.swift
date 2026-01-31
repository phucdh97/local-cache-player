//
//  VideoCacheQuerying.swift
//  VideoDemo
//
//  Protocol for UI and player layer cache queries (Clean Architecture - Dependency Inversion)
//  High-level code depends on this abstraction, not on concrete VideoCacheService
//

import Foundation

/// Protocol abstracting UI-facing cache query operations
/// Allows UI layer to depend on abstraction rather than concrete implementation
protocol VideoCacheQuerying: AnyObject {
    /// Get cache percentage for a video (0.0 to 100.0)
    func getCachePercentage(for url: URL) -> Double
    
    /// Check if video is fully cached
    func isCached(url: URL) -> Bool
    
    /// Get cached file size for a specific video in bytes
    func getCachedFileSize(for url: URL) -> Int64
    
    /// Get total cache size in bytes
    func getCacheSize() -> Int64
    
    /// Clear all cached content
    func clearCache()
}
