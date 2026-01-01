//
//  VideoCacheManager.swift
//  VideoDemo
//
//  Cache manager for video data with progressive caching support
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import AVFoundation

// MARK: - Cache Metadata

struct CacheMetadata: Codable {
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

struct CachedRange: Codable {
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

// MARK: - VideoCacheManager

class VideoCacheManager {
    static let shared = VideoCacheManager()
    
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let memoryCache = NSCache<NSString, NSData>()
    private let metadataQueue = DispatchQueue(label: "com.videocache.metadata", attributes: .concurrent)
    
    private var metadataCache: [String: CacheMetadata] = [:]
    private let metadataCacheLock = NSLock()  // Add lock for thread safety
    
    private init() {
        // Create cache directory
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("VideoCache")
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
        
        // Configure memory cache
        memoryCache.countLimit = 50
        memoryCache.totalCostLimit = 100 * 1024 * 1024 // 100 MB
        
        print("📦 Video cache directory: \(cacheDirectory.path)")
    }
    
    // MARK: - Cache Key Generation
    
    func cacheKey(for url: URL) -> String {
        return url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.lastPathComponent
    }
    
    func cacheFilePath(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent(key)
    }
    
    func metadataFilePath(for url: URL) -> URL {
        let key = cacheKey(for: url)
        return cacheDirectory.appendingPathComponent("\(key).metadata")
    }
    
    // MARK: - Metadata Operations
    
    func getCacheMetadata(for url: URL) -> CacheMetadata? {
        let key = cacheKey(for: url)
        
        // Check in-memory cache (thread-safe)
        metadataCacheLock.lock()
        let cached = metadataCache[key]
        metadataCacheLock.unlock()
        
        if let metadata = cached {
            return metadata
        }
        
        // Load from disk
        let metadataPath = metadataFilePath(for: url)
        guard fileManager.fileExists(atPath: metadataPath.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: metadataPath)
            let metadata = try JSONDecoder().decode(CacheMetadata.self, from: data)
            
            metadataCacheLock.lock()
            metadataCache[key] = metadata
            metadataCacheLock.unlock()
            
            return metadata
        } catch {
            print("❌ Error loading metadata: \(error)")
            return nil
        }
    }
    
    func saveCacheMetadata(for url: URL, contentLength: Int64?, contentType: String?) {
        let key = cacheKey(for: url)
        var metadata = getCacheMetadata(for: url) ?? CacheMetadata()
        
        if let contentLength = contentLength {
            metadata.contentLength = contentLength
        }
        if let contentType = contentType {
            metadata.contentType = contentType
        }
        metadata.lastModified = Date()
        
        metadataCacheLock.lock()
        metadataCache[key] = metadata
        metadataCacheLock.unlock()
        
        saveMetadataToDisk(metadata, for: url)
    }
    
    private func saveMetadataToDisk(_ metadata: CacheMetadata, for url: URL) {
        let metadataPath = metadataFilePath(for: url)
        
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataPath)
        } catch {
            print("❌ Error saving metadata: \(error)")
        }
    }
    
    // MARK: - Range Operations
    
    func addCachedRange(for url: URL, offset: Int64, length: Int64) {
        let key = cacheKey(for: url)
        var metadata = getCacheMetadata(for: url) ?? CacheMetadata()
        
        let newRange = CachedRange(offset: offset, length: length)
        metadata.cachedRanges.append(newRange)
        
        // Merge overlapping ranges
        metadata.cachedRanges = mergeOverlappingRanges(metadata.cachedRanges)
        metadata.lastModified = Date()
        
        metadataCacheLock.lock()
        metadataCache[key] = metadata
        metadataCacheLock.unlock()
        
        saveMetadataToDisk(metadata, for: url)
        
        print("📊 Range cached: \(offset)-\(offset+length), total ranges: \(metadata.cachedRanges.count)")
    }
    
    func isRangeCached(for url: URL, offset: Int64, length: Int64) -> Bool {
        guard let metadata = getCacheMetadata(for: url) else {
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
    
    func markAsFullyCached(for url: URL, size: Int64) {
        let key = cacheKey(for: url)
        var metadata = getCacheMetadata(for: url) ?? CacheMetadata()
        
        metadata.isFullyCached = true
        metadata.contentLength = size
        metadata.lastModified = Date()
        
        metadataCacheLock.lock()
        metadataCache[key] = metadata
        metadataCacheLock.unlock()
        
        saveMetadataToDisk(metadata, for: url)
        
        print("✅ Video fully cached: \(url.lastPathComponent) (\(size) bytes)")
    }
    
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
    
    // MARK: - Cache Operations
    
    func isCached(url: URL) -> Bool {
        if let metadata = getCacheMetadata(for: url), metadata.isFullyCached {
            return true
        }
        return false
    }
    
    func getCachePercentage(for url: URL) -> Double {
        guard let metadata = getCacheMetadata(for: url),
              let contentLength = metadata.contentLength,
              contentLength > 0 else {
            return 0.0
        }
        
        let cachedSize = getCachedDataSize(for: url)
        let percentage = (Double(cachedSize) / Double(contentLength)) * 100.0
        return min(percentage, 100.0) // Cap at 100%
    }
    
    func isPartiallyCached(for url: URL) -> Bool {
        let percentage = getCachePercentage(for: url)
        return percentage > 0 && percentage < 100
    }
    
    func getCachedDataSize(for url: URL) -> Int64 {
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
    
    func cachedData(for url: URL, offset: Int64, length: Int) -> Data? {
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
        
        // Calculate how much data we can actually return (might be less than requested)
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
    
    func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
        let filePath = cacheFilePath(for: url)
        
        do {
            if !fileManager.fileExists(atPath: filePath.path) {
                // Create file if it doesn't exist
                fileManager.createFile(atPath: filePath.path, contents: nil)
            }
            
            let fileHandle = try FileHandle(forWritingTo: filePath)
            defer { try? fileHandle.close() }
            
            try fileHandle.seek(toOffset: UInt64(offset))
            fileHandle.write(data)
            
            print("💾 Cached chunk: \(data.count) bytes at offset \(offset)")
        } catch {
            print("❌ Error caching chunk: \(error)")
        }
    }
    
    func cacheData(_ data: Data, for url: URL, append: Bool = false) {
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
    
    func getCachedFileSize(for url: URL) -> Int64? {
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
    
    func clearCache() {
        memoryCache.removeAllObjects()
        
        metadataCacheLock.lock()
        metadataCache.removeAll()
        metadataCacheLock.unlock()
        
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
    
    func getCacheSize() -> Int64 {
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

