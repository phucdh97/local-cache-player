//
//  VideoCacheQueryingAsync.swift
//  VideoDemo
//
//  Async protocol for UI-facing cache queries (Clean Architecture)
//  Non-blocking operations safe for main thread usage
//

import Foundation

/// Protocol abstracting UI-facing cache query operations with async support
/// All methods are non-blocking and can be safely called from any thread
/// Requires iOS 17+ (app minimum deployment target)
protocol VideoCacheQueryingAsync: AnyObject {
    /// Get cache percentage for a video (0.0 to 100.0)
    /// - Parameter url: Video URL
    /// - Returns: Cache percentage (0-100)
    func getCachePercentage(for url: URL) async -> Double
    
    /// Check if video is fully cached
    /// - Parameter url: Video URL
    /// - Returns: true if fully cached
    func isCached(url: URL) async -> Bool
    
    /// Get cached file size for a specific video in bytes
    /// - Parameter url: Video URL
    /// - Returns: Cached size in bytes
    func getCachedFileSize(for url: URL) async -> Int64
    
    /// Get total cache size in bytes
    /// - Returns: Total cache size
    func getCacheSize() async -> Int64
    
    /// Clear all cached content
    func clearCache() async
}
