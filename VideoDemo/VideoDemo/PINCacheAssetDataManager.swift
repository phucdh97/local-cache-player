//
//  PINCacheAssetDataManager.swift
//  VideoDemo
//
//  PINCache-based implementation with range-based chunk storage
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import PINCache

/// PINCache-based cache manager with range tracking for non-sequential data
/// Suitable for small-medium videos (<100MB)
/// For large videos, consider FileHandleAssetDataManager instead
class PINCacheAssetDataManager: NSObject, AssetDataManager {
    
    /// Shared PINCache instance with configured limits
    /// Memory: 20MB for fast access to recent chunks
    /// Disk: 500MB for persistent storage with LRU eviction
    static let Cache: PINCache = {
        let cache = PINCache(name: "ResourceLoader")
        
        // Configure memory cache: 20MB limit
        cache.memoryCache.costLimit = 20 * 1024 * 1024
        
        // Configure disk cache: 500MB limit with LRU eviction
        cache.diskCache.byteLimit = 500 * 1024 * 1024
        
        print("📦 PINCache initialized: Memory=\(formatBytes(20 * 1024 * 1024)), Disk=\(formatBytes(500 * 1024 * 1024)) (Range-Based)")
        return cache
    }()
    
    let cacheKey: String
    
    init(cacheKey: String) {
        self.cacheKey = cacheKey
        super.init()
    }
    
    // MARK: - AssetDataManager Protocol
    
    func retrieveAssetData() -> AssetData? {
        guard let assetData = PINCacheAssetDataManager.Cache.object(forKey: cacheKey) as? AssetData else {
            print("📦 Cache miss for \(cacheKey)")
            return nil
        }
        
        // MIGRATION: Convert old sequential cache to range-based
        if assetData.mediaData.count > 0 && assetData.cachedRanges.isEmpty {
            let range = CachedRange(offset: 0, length: Int64(assetData.mediaData.count))
            assetData.cachedRanges = [range]
            
            // Migrate to chunk storage
            let chunkKey = "\(cacheKey)_chunk_0"
            PINCacheAssetDataManager.Cache.setObjectAsync(assetData.mediaData as NSData, forKey: chunkKey)
            assetData.mediaData = Data()  // Clear to save memory
            
            PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey)
            
            print("🔄 Migrated old cache to range-based storage (1 range, \(formatBytes(range.length)))")
        }
        
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        print("📦 Cache hit for \(cacheKey): \(formatBytes(totalCached)) in \(assetData.cachedRanges.count) range(s), contentLength=\(formatBytes(assetData.contentInformation.contentLength))")
        return assetData
    }
    
    func saveContentInformation(_ contentInformation: AssetDataContentInformation) {
        let assetData = retrieveAssetData() ?? AssetData()
        assetData.contentInformation = contentInformation
        
        // Async write to avoid blocking (PINCache handles thread safety)
        PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
        
        print("📋 Content info saved: \(formatBytes(contentInformation.contentLength))")
    }
    
    func saveDownloadedData(_ data: Data, offset: Int) {
        let assetData = retrieveAssetData() ?? AssetData()
        
        // Ensure we have content information
        guard assetData.contentInformation.contentLength > 0 else {
            print("⚠️ No content info for \(cacheKey), skipping save")
            return
        }
        
        let existingRanges = assetData.cachedRanges.count
        let totalBefore = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        
        print("🔄 Saving chunk: \(formatBytes(data.count)) at offset \(offset) for \(cacheKey)")
        
        // Store chunk separately with range key
        let chunkKey = "\(cacheKey)_chunk_\(offset)"
        PINCacheAssetDataManager.Cache.setObjectAsync(data as NSData, forKey: chunkKey)
        
        // Add to range tracking
        let newRange = CachedRange(offset: Int64(offset), length: Int64(data.count))
        assetData.cachedRanges.append(newRange)
        
        // Merge overlapping/adjacent ranges
        assetData.cachedRanges = mergeRanges(assetData.cachedRanges)
        
        let totalAfter = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        let rangesAfter = assetData.cachedRanges.count
        
        // Update main entry
        PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
        
        print("✅ Chunk cached: \(existingRanges) → \(rangesAfter) ranges, \(formatBytes(totalBefore)) → \(formatBytes(totalAfter)) (+\(formatBytes(totalAfter - totalBefore)))")
    }
    
    // MARK: - Range-Based Queries
    
    func isRangeCached(offset: Int64, length: Int) -> Bool {
        guard let assetData = retrieveAssetData() else { return false }
        
        for range in assetData.cachedRanges {
            if range.contains(offset: offset, length: Int64(length)) {
                return true
            }
        }
        
        return false
    }
    
    func retrieveDataInRange(offset: Int64, length: Int) -> Data? {
        guard let assetData = retrieveAssetData() else { return nil }
        
        var result = Data()
        var currentOffset = offset
        let endOffset = offset + Int64(length)
        
        // Sort ranges by offset for sequential assembly
        let sortedRanges = assetData.cachedRanges.sorted { $0.offset < $1.offset }
        
        for range in sortedRanges {
            // Skip ranges that end before our current position
            guard range.offset + range.length > currentOffset else { continue }
            
            // Stop if we've collected enough data
            guard currentOffset < endOffset else { break }
            
            // Check if there's a gap
            if range.offset > currentOffset {
                print("⚠️ Gap detected: need \(currentOffset)-\(range.offset), returning partial/nil")
                // Return what we have so far, or nil if nothing
                return result.count > 0 ? result : nil
            }
            
            // Load chunk for this range
            let chunkKey = "\(cacheKey)_chunk_\(range.offset)"
            guard let chunkData = PINCacheAssetDataManager.Cache.object(forKey: chunkKey) as? Data else {
                print("⚠️ Range \(range.offset)-\(range.offset+range.length) indexed but chunk missing")
                return result.count > 0 ? result : nil
            }
            
            // Calculate which part of this chunk we need
            let startInChunk = max(0, Int(currentOffset - range.offset))
            let endInChunk = min(chunkData.count, Int(endOffset - range.offset))
            
            if startInChunk < endInChunk {
                let subdata = chunkData.subdata(in: startInChunk..<endInChunk)
                result.append(subdata)
                currentOffset = range.offset + Int64(endInChunk)
                
                let rangeEnd = range.offset + range.length
                print("📥 Retrieved \(formatBytes(subdata.count)) from range \(range.offset)-\(rangeEnd) (\(formatBytes(range.offset))-\(formatBytes(rangeEnd)))")
            }
        }
        
        // Check if we got everything requested
        if currentOffset >= endOffset {
            print("✅ Complete range retrieved: \(formatBytes(result.count)) from \(offset)")
            return result
        } else if result.count > 0 {
            print("⚡️ Partial range retrieved: \(formatBytes(result.count)) from \(offset) (requested \(formatBytes(length)))")
            return result
        } else {
            print("❌ No data available for range \(offset)-\(endOffset) (\(formatBytes(offset))-\(formatBytes(endOffset)))")
            return nil
        }
    }
    
    // MARK: - Range Merging
    
    /// Merge overlapping and adjacent ranges
    private func mergeRanges(_ ranges: [CachedRange]) -> [CachedRange] {
        guard ranges.count > 1 else { return ranges }
        
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var merged: [CachedRange] = []
        var current = sorted[0]
        
        for i in 1..<sorted.count {
            let next = sorted[i]
            
            // Check if ranges should be merged (overlapping or adjacent)
            if current.overlaps(with: next) || current.isAdjacentTo(next) {
                // Merge: extend current to cover both ranges
                let newEnd = max(current.offset + current.length, next.offset + next.length)
                let newLength = newEnd - current.offset
                
                let oldLength = current.length
                current = CachedRange(offset: current.offset, length: newLength)
                
                print("🔗 Merged ranges: \(current.offset)-\(current.offset+oldLength) + \(next.offset)-\(next.offset+next.length) = \(current.offset)-\(current.offset+current.length)")
            } else {
                // Gap exists - keep ranges separate
                merged.append(current)
                current = next
            }
        }
        
        merged.append(current)
        return merged
    }
}
