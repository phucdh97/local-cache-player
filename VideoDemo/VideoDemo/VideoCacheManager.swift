//
//  VideoCacheManager.swift
//  VideoDemo
//
//  Cache manager for video data with progressive caching support
//  Thread-safe Actor-based implementation for metadata management
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//  
//  Architecture:
//  - Actor for metadata (thread-safe dictionary operations)
//  - FileHandle for video chunks (direct disk I/O, non-isolated)
//  - No PINCache dependency (unsuitable for large videos per ZPlayerCacher author)
//

import Foundation
import AVFoundation

// MARK: - Cache Metadata

struct CacheMetadata: Codable, Sendable {
    var contentLength: Int64?
    var contentType: String?
    var cachedRanges: [CachedRange]
    var isFullyCached: Bool
    var lastModified: Date
    
    init() {
        self.cachedRanges = []
        self.isFullyCached = false
        self.lastModified = Date()
    }
}

struct CachedRange: Codable, Sendable {
    let offset: Int64
    let length: Int64
    
    func contains(offset: Int64, length: Int64) -> Bool {
        return offset >= self.offset && (offset + length) <= (self.offset + self.length)
    }
    
    func overlaps(with other: CachedRange) -> Bool {
        let thisEnd = self.offset + self.length
        let otherEnd = other.offset + other.length
        return !(self.offset >= otherEnd || other.offset >= thisEnd)
    }
}

// MARK: - VideoCacheManager Actor

/// Thread-safe video cache manager using Swift Actor for metadata operations
/// 
/// Key Design Decisions:
/// - Actor ensures thread safety for metadata dictionary (no manual NSLock needed)
/// - FileHandle operations are non-isolated for performance (FileHandle is thread-safe)
/// - Avoids loading entire videos into memory (unlike PINCache approach)
/// - Supports progressive caching with range-based tracking
actor VideoCacheManager {
    static let shared = VideoCacheManager()
    
    // Thread-safe metadata storage (protected by Actor)
    private var metadataCache: [String: CacheMetadata] = [:]
    
    // File system access (non-isolated operations use these)
    nonisolated let fileManager = FileManager.default
    nonisolated let cacheDirectory: URL
    nonisolated let memoryCache = NSCache<NSString, NSData>()
    
    private init() {
        // Create cache directory
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("VideoCache")
        
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        
        // Configure memory cache
        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        print("📦 Video cache directory: \(cacheDirectory.path)")
    }
    
    // MARK: - Cache Key Generation (non-isolated for performance)
    
    /// Generate cache key from URL
    /// Non-isolated: Pure function, no shared state access
    nonisolated func cacheKey(for url: URL) -> String {
        return url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.lastPathComponent
    }
    
    /// Get file path for cached video data
    /// Non-isolated: Read-only access to immutable cacheDirectory
    nonisolated func cacheFilePath(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key)
    }
    
    /// Get file path for metadata
    /// Non-isolated: Read-only access to immutable cacheDirectory
    nonisolated func metadataFilePath(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent("\(key).metadata")
    }
    
    // MARK: - Metadata Operations (Actor-isolated for thread safety)
    
    /// Get cached metadata for a URL
    /// Actor-isolated: Thread-safe access to metadataCache dictionary
    /// 
    /// Flow:
    /// 1. Check in-memory cache (actor-protected dictionary)
    /// 2. If not found, load from disk
    /// 3. Cache in memory for future access
    func getCacheMetadata(for url: URL) -> CacheMetadata? {
        let key = cacheKey(for: url)
        
        // Check in-memory cache (✅ Thread-safe via Actor)
        if let cached = metadataCache[key] {
            return cached
        }
        
        // Load from disk
        let metadataPath = metadataFilePath(for: url)
        guard fileManager.fileExists(atPath: metadataPath.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: metadataPath)
            let metadata = try JSONDecoder().decode(CacheMetadata.self, from: data)
            
            // Cache in memory (✅ Thread-safe via Actor)
            metadataCache[key] = metadata
            
            return metadata
        } catch {
            print("❌ Error loading metadata: \(error)")
            return nil
        }
    }
    
    /// Save content information to metadata
    /// Actor-isolated: Thread-safe metadata updates
    func saveCacheMetadata(for url: URL, contentLength: Int64?, contentType: String?) {
        let key = cacheKey(for: url)
        var metadata = metadataCache[key] ?? CacheMetadata()
        
        if let contentLength = contentLength {
            metadata.contentLength = contentLength
        }
        if let contentType = contentType {
            metadata.contentType = contentType
        }
        metadata.lastModified = Date()
        
        // Update in-memory cache (✅ Thread-safe via Actor)
        metadataCache[key] = metadata
        
        // Save to disk (async to avoid blocking)
        Task.detached { [metadata, url, metadataPath = metadataFilePath(for: url)] in
            do {
                let data = try JSONEncoder().encode(metadata)
                try data.write(to: metadataPath)
            } catch {
                print("❌ Error saving metadata: \(error)")
            }
        }
    }
    
    // MARK: - Range Operations (Actor-isolated for thread safety)
    
    /// Add a cached range to metadata
    /// Actor-isolated: Thread-safe updates to cached ranges
    /// 
    /// Addresses Issue #3: Dictionary corruption when switching videos
    /// Actor ensures only one thread modifies metadata at a time
    func addCachedRange(for url: URL, offset: Int64, length: Int64) {
        let key = cacheKey(for: url)
        var metadata = metadataCache[key] ?? CacheMetadata()
        
        let newRange = CachedRange(offset: offset, length: length)
        metadata.cachedRanges.append(newRange)
        
        // Merge overlapping ranges (addresses Issue #2: Keep it simple!)
        metadata.cachedRanges = mergeOverlappingRanges(metadata.cachedRanges)
        metadata.lastModified = Date()
        
        // Update in-memory cache (✅ Thread-safe via Actor)
        metadataCache[key] = metadata
        
        // Save to disk asynchronously
        Task.detached { [metadata, url, metadataPath = metadataFilePath(for: url)] in
            do {
                let data = try JSONEncoder().encode(metadata)
                try data.write(to: metadataPath)
            } catch {
                print("❌ Error saving metadata: \(error)")
            }
        }
        
        print("📊 Range cached: \(offset)-\(offset+length), total ranges: \(metadata.cachedRanges.count)")
    }
    
    /// Check if a specific range is cached
    /// Actor-isolated: Thread-safe read from metadata
    func isRangeCached(for url: URL, offset: Int64, length: Int64) -> Bool {
        guard let metadata = metadataCache[cacheKey(for: url)] else {
            return false
        }
        
        // If fully cached, any range is available
        if metadata.isFullyCached {
            return true
        }
        
        // Check if requested range is covered by any cached range
        for range in metadata.cachedRanges {
            if range.contains(offset: offset, length: length) {
                return true
            }
        }
        
        return false
    }
    
    /// Mark video as fully cached
    /// Actor-isolated: Thread-safe metadata update
    func markAsFullyCached(for url: URL, size: Int64) {
        let key = cacheKey(for: url)
        var metadata = metadataCache[key] ?? CacheMetadata()
        
        metadata.isFullyCached = true
        metadata.contentLength = size
        metadata.lastModified = Date()
        
        // Update in-memory cache (✅ Thread-safe via Actor)
        metadataCache[key] = metadata
        
        // Save to disk asynchronously
        Task.detached { [metadata, url, metadataPath = metadataFilePath(for: url)] in
            do {
                let data = try JSONEncoder().encode(metadata)
                try data.write(to: metadataPath)
            } catch {
                print("❌ Error saving metadata: \(error)")
            }
        }
        
        print("✅ Video fully cached: \(url.lastPathComponent) (\(size) bytes)")
    }
    
    /// Merge overlapping or adjacent ranges
    /// Private helper: Keeps range list compact
    /// 
    /// Addresses Issue #2: Simple range management, no complex offset calculations
    private func mergeOverlappingRanges(_ ranges: [CachedRange]) -> [CachedRange] {
        guard ranges.count > 1 else { return ranges }
        
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var merged: [CachedRange] = []
        var current = sorted[0]
        
        for i in 1..<sorted.count {
            let next = sorted[i]
            
            if current.overlaps(with: next) || current.offset + current.length == next.offset {
                // Merge ranges
                let newLength = max(current.offset + current.length, next.offset + next.length) - current.offset
                current = CachedRange(offset: current.offset, length: newLength)
            } else {
                merged.append(current)
                current = next
            }
        }
        
        merged.append(current)
        return merged
    }
    
    // MARK: - Cache Operations (Actor-isolated for metadata, non-isolated for disk I/O)
    
    /// Check if video is fully cached
    /// Actor-isolated: Thread-safe metadata read
    func isCached(url: URL) -> Bool {
        if let metadata = metadataCache[cacheKey(for: url)], metadata.isFullyCached {
            return true
        }
        return false
    }
    
    /// Get cache percentage for a video
    /// Actor-isolated: Thread-safe metadata access
    func getCachePercentage(for url: URL) -> Double {
        guard let metadata = metadataCache[cacheKey(for: url)],
              let contentLength = metadata.contentLength,
              contentLength > 0 else {
            return 0.0
        }
        
        let cachedSize = getCachedDataSize(for: url)
        let percentage = (Double(cachedSize) / Double(contentLength)) * 100.0
        return min(percentage, 100.0) // Cap at 100%
    }
    
    /// Check if video is partially cached
    /// Actor-isolated: Uses actor-protected percentage calculation
    func isPartiallyCached(for url: URL) -> Bool {
        let percentage = getCachePercentage(for: url)
        return percentage > 0 && percentage < 100
    }
    
    /// Get size of cached data on disk
    /// Non-isolated: Direct file system access (no shared state)
    nonisolated func getCachedDataSize(for url: URL) -> Int64 {
        let filePath = cacheFilePath(for: url)
        guard fileManager.fileExists(atPath: filePath.path) else {
            return 0
        }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: filePath.path)
            return attributes[.size] as? Int64 ?? 0
        } catch {
            return 0
        }
    }
    
    /// Read cached data from disk
    /// Non-isolated: FileHandle operations are thread-safe
    /// 
    /// Addresses Issue #5: Serves partial data for progressive playback
    /// Returns whatever data is available, even if less than requested
    nonisolated func cachedData(for url: URL, offset: Int64, length: Int) -> Data? {
        let filePath = cacheFilePath(for: url)
        guard fileManager.fileExists(atPath: filePath.path) else {
            return nil
        }
        
        // Get the actual cached size
        let cachedSize = getCachedDataSize(for: url)
        
        // If requested offset is beyond what we have, return nil
        guard offset < cachedSize else {
            return nil
        }
        
        // ✅ Calculate how much data we can actually return (might be less than requested)
        // This enables progressive playback - don't wait for full range!
        let availableLength = min(Int64(length), cachedSize - offset)
        
        guard availableLength > 0 else {
            return nil
        }
        
        do {
            let fileHandle = try FileHandle(forReadingFrom: filePath)
            defer { try? fileHandle.close() }
            
            try fileHandle.seek(toOffset: UInt64(offset))
            let data = fileHandle.readData(ofLength: Int(availableLength))
            return data.isEmpty ? nil : data
        } catch {
            print("❌ Error reading cached data: \(error)")
            return nil
        }
    }
    
    /// Write video chunk to disk at specific offset
    /// Non-isolated: FileHandle write operations are thread-safe
    /// 
    /// Key Design: Unlike PINCache (stores entire video in memory),
    /// this writes directly to disk with FileHandle, supporting videos of ANY size
    /// 
    /// Addresses Issue #2: Simple chunk storage with absolute offsets (no complex calculations)
    nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
        let filePath = cacheFilePath(for: url)
        
        do {
            if !fileManager.fileExists(atPath: filePath.path) {
                // Create file if it doesn't exist
                fileManager.createFile(atPath: filePath.path, contents: nil)
            }
            
            let fileHandle = try FileHandle(forWritingTo: filePath)
            defer { try? fileHandle.close() }
            
            // ✅ Write at specific offset - enables progressive caching
            try fileHandle.seek(toOffset: UInt64(offset))
            fileHandle.write(data)
            
            print("💾 Cached chunk: \(data.count) bytes at offset \(offset)")
        } catch {
            print("❌ Error caching chunk: \(error)")
        }
    }
    
    /// Write or append video data
    /// Non-isolated: FileHandle operations
    nonisolated func cacheData(_ data: Data, for url: URL, append: Bool = false) {
        let filePath = cacheFilePath(for: url)
        
        do {
            if append && fileManager.fileExists(atPath: filePath.path) {
                let fileHandle = try FileHandle(forWritingTo: filePath)
                defer { try? fileHandle.close() }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
            } else {
                try data.write(to: filePath)
            }
            
            print("💾 Cached \(data.count) bytes for \(url.lastPathComponent)")
        } catch {
            print("❌ Error caching data: \(error)")
        }
    }
    
    /// Get size of cached file
    /// Non-isolated: Direct file system query
    nonisolated func getCachedFileSize(for url: URL) -> Int64? {
        let filePath = cacheFilePath(for: url)
        guard fileManager.fileExists(atPath: filePath.path) else {
            return nil
        }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: filePath.path)
            return attributes[.size] as? Int64
        } catch {
            return nil
        }
    }
    
    /// Clear all cached videos and metadata
    /// Actor-isolated: Modifies metadataCache dictionary
    func clearCache() {
        memoryCache.removeAllObjects()
        
        // Clear in-memory metadata (✅ Thread-safe via Actor)
        metadataCache.removeAll()
        
        // Clear disk cache
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in contents {
                try fileManager.removeItem(at: file)
            }
            print("🗑️ Cache cleared")
        } catch {
            print("❌ Error clearing cache: \(error)")
        }
    }
    
    /// Get total size of all cached videos
    /// Non-isolated: File system scanning
    nonisolated func getCacheSize() -> Int64 {
        var totalSize: Int64 = 0
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
            for file in contents {
                // Skip metadata files
                if file.pathExtension == "metadata" {
                    continue
                }
                
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                totalSize += attributes[.size] as? Int64 ?? 0
            }
        } catch {
            print("❌ Error calculating cache size: \(error)")
        }
        
        return totalSize
    }
}

// MARK: - Thread Safety Summary
//
// ✅ Metadata Operations (Actor-isolated):
//    - getCacheMetadata()
//    - saveCacheMetadata()
//    - addCachedRange()
//    - isRangeCached()
//    - markAsFullyCached()
//    - isCached()
//    - getCachePercentage()
//    - isPartiallyCached()
//    - clearCache()
//
// ✅ File Operations (Non-isolated):
//    - cacheKey()
//    - cacheFilePath()
//    - metadataFilePath()
//    - getCachedDataSize()
//    - cachedData()
//    - cacheChunk()
//    - cacheData()
//    - getCachedFileSize()
//    - getCacheSize()
//
// Why this works:
// 1. Actor serializes access to metadataCache dictionary (no race conditions)
// 2. FileHandle operations are inherently thread-safe
// 3. No manual NSLock needed - Swift Actor handles synchronization
// 4. Addresses all issues from ISSUES_AND_SOLUTIONS.md:
//    - Issue #2: Simple chunk storage, no complex offset math
//    - Issue #3: Thread-safe dictionary via Actor (no corruption)
//    - Issue #5: Serves partial data for progressive playback
//

