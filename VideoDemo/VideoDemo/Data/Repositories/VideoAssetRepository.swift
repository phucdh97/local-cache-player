//
//  VideoAssetRepository.swift
//  VideoDemo
//
//  Cache-based repository implementation with range-based chunk storage
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//
//  Refactored to use dependency injection (Clean Architecture)
//  Repository pattern: Handles data persistence/retrieval for video assets
//

import Foundation

/// Asset data repository with range tracking for non-sequential data
/// Suitable for small-medium videos (<100MB)
/// For large videos, consider FileHandle-based implementation instead
/// 
/// Uses injected CacheStorage instead of concrete PINCache (Clean Architecture)
class VideoAssetRepository: NSObject, AssetDataRepository {
    
    /// Injected cache storage (dependency inversion)
    private let cache: CacheStorage
    
    let cacheKey: String
    
    /// Initialize with injected cache dependency
    /// - Parameters:
    ///   - cacheKey: Unique key for this asset
    ///   - cache: Cache storage implementation (injected)
    init(cacheKey: String, cache: CacheStorage) {
        self.cacheKey = cacheKey
        self.cache = cache
        super.init()
    }
    
    // MARK: - AssetDataRepository Protocol
    
    func retrieveAssetData() -> AssetData? {
        guard let assetData = cache.object(forKey: cacheKey) as? AssetData else {
            print("📦 Cache miss for \(cacheKey)")
            return nil
        }
        
        // MIGRATION: Convert old sequential cache to range-based
        if assetData.mediaData.count > 0 && assetData.cachedRanges.isEmpty {
            let range = CachedRange(offset: 0, length: Int64(assetData.mediaData.count))
            assetData.cachedRanges = [range]
            assetData.chunkOffsets = [0]  // Track chunk offset
            
            // Migrate to chunk storage
            let chunkKey = "\(cacheKey)_chunk_0"
            cache.setObjectAsync(assetData.mediaData as NSData, forKey: chunkKey)
            assetData.mediaData = Data()  // Clear to save memory
            
            cache.setObjectAsync(assetData, forKey: cacheKey)
            
            print("🔄 Migrated old cache to range-based storage (1 range, \(formatBytes(range.length)))")
        }
        
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        print("📦 Cache hit for \(cacheKey): \(formatBytes(totalCached)) in \(assetData.cachedRanges.count) range(s), contentLength=\(formatBytes(assetData.contentInformation.contentLength))")
        print("📌 Available chunk offsets: [\(assetData.chunkOffsets.map { formatBytes($0.int64Value) }.joined(separator: ", "))]")
        return assetData
    }
    
    func saveContentInformation(_ contentInformation: AssetDataContentInformation) {
        let assetData = retrieveAssetData() ?? AssetData()
        assetData.contentInformation = contentInformation
        
        // Async write to avoid blocking (cache handles thread safety)
        cache.setObjectAsync(assetData, forKey: cacheKey)
        
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
        cache.setObjectAsync(data as NSData, forKey: chunkKey)
        print("💾 Stored chunk with key: \(chunkKey), size: \(formatBytes(data.count))")
        
        // Track chunk offset (avoid duplicates)
        let offsetNumber = NSNumber(value: offset)
        if !assetData.chunkOffsets.contains(offsetNumber) {
            assetData.chunkOffsets.append(offsetNumber)
            assetData.chunkOffsets.sort { $0.int64Value < $1.int64Value }
            print("📌 Added chunk offset \(formatBytes(Int64(offset))), total offsets: \(assetData.chunkOffsets.count)")
        } else {
            print("⚠️ Duplicate chunk offset \(formatBytes(Int64(offset))), skipping")
        }
        print("📌 Tracked offsets: [\(assetData.chunkOffsets.map { formatBytes($0.int64Value) }.joined(separator: ", "))]")
        
        // Add to range tracking
        let newRange = CachedRange(offset: Int64(offset), length: Int64(data.count))
        assetData.cachedRanges.append(newRange)
        
        // Merge overlapping/adjacent ranges
        assetData.cachedRanges = mergeRanges(assetData.cachedRanges)
        
        let totalAfter = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        let rangesAfter = assetData.cachedRanges.count
        
        // Update main entry
        cache.setObjectAsync(assetData, forKey: cacheKey)
        
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
        
        print("🔎 retrieveDataInRange: Request \(formatBytes(offset))-\(formatBytes(offset + Int64(length))) (\(formatBytes(length)))")
        
        var result = Data()
        var currentOffset = offset
        let endOffset = offset + Int64(length)
        
        // Get all chunk keys to find which chunks cover merged ranges
        let allChunkKeys = getAllChunkKeys(for: assetData.cachedRanges)
        
        print("🔎 retrieveDataInRange: Processing \(allChunkKeys.count) available chunk(s)")
        
        // Sort chunks by their offset
        let sortedChunks = allChunkKeys.sorted { $0.offset < $1.offset }
        
        for chunkInfo in sortedChunks {
            // Skip chunks that end before our current position
            let chunkEnd = chunkInfo.offset + Int64(chunkInfo.length)
            guard chunkEnd > currentOffset else { 
                print("🔎   ⏭️  Skipping chunk at \(formatBytes(chunkInfo.offset)) (ends before current position)")
                continue 
            }
            
            // Stop if we've collected enough data
            guard currentOffset < endOffset else { 
                print("🔎   ✅ Collected enough data, stopping")
                break 
            }
            
            // Check if there's a gap between current position and this chunk
            if chunkInfo.offset > currentOffset {
                print("⚠️ Gap detected: need \(formatBytes(currentOffset))-\(formatBytes(chunkInfo.offset)), returning partial")
                // Return what we have so far, or nil if nothing
                return result.count > 0 ? result : nil
            }
            
            // Load chunk data
            let chunkKey = "\(cacheKey)_chunk_\(chunkInfo.offset)"
            guard let chunkData = cache.object(forKey: chunkKey) as? Data else {
                print("⚠️ Chunk at \(formatBytes(chunkInfo.offset)) indexed but data missing")
                return result.count > 0 ? result : nil
            }
            
            // Verify chunk size matches metadata
            guard chunkData.count == chunkInfo.length else {
                print("⚠️ Chunk size mismatch: expected \(formatBytes(chunkInfo.length)), got \(formatBytes(chunkData.count))")
                return result.count > 0 ? result : nil
            }
            
            // Calculate which part of this chunk we need
            let startInChunk = max(0, Int(currentOffset - chunkInfo.offset))
            let endInChunk = min(chunkData.count, Int(endOffset - chunkInfo.offset))
            
            if startInChunk < endInChunk {
                let subdata = chunkData.subdata(in: startInChunk..<endInChunk)
                result.append(subdata)
                currentOffset = chunkInfo.offset + Int64(endInChunk)
                
                print("📥 Retrieved \(formatBytes(subdata.count)) from chunk at \(formatBytes(chunkInfo.offset)) (range \(formatBytes(chunkInfo.offset))-\(formatBytes(chunkEnd)))")
            }
        }
        
        // Check if we got everything requested
        if currentOffset >= endOffset {
            print("✅ Complete range retrieved: \(formatBytes(result.count)) from \(formatBytes(offset))")
            return result
        } else if result.count > 0 {
            print("⚡️ Partial range retrieved: \(formatBytes(result.count)) from \(formatBytes(offset)) (requested \(formatBytes(length)))")
            return result
        } else {
            print("❌ No data available for range \(formatBytes(offset))-\(formatBytes(endOffset))")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    /// Get all chunk metadata using the tracked chunk offsets
    private func getAllChunkKeys(for ranges: [CachedRange]) -> [(offset: Int64, length: Int)] {
        guard let assetData = retrieveAssetData() else { 
            print("🔍 getAllChunkKeys: No asset data available")
            return [] 
        }
        
        print("🔍 getAllChunkKeys: Scanning \(assetData.chunkOffsets.count) tracked chunk offset(s)")
        
        var chunks: [(offset: Int64, length: Int)] = []
        var missingCount = 0
        
        // Use the tracked chunk offsets instead of searching sequentially
        for offsetNumber in assetData.chunkOffsets {
            let offset = offsetNumber.int64Value
            let chunkKey = "\(cacheKey)_chunk_\(offset)"
            
            if let chunkData = cache.object(forKey: chunkKey) as? Data {
                chunks.append((offset: offset, length: chunkData.count))
                print("🔍   ✅ Chunk at \(formatBytes(offset)): \(formatBytes(chunkData.count))")
            } else {
                missingCount += 1
                print("⚠️ Chunk offset \(formatBytes(offset)) tracked but data missing (key: \(chunkKey))")
            }
        }
        
        let sortedChunks = chunks.sorted { $0.offset < $1.offset }
        print("🔍 getAllChunkKeys: Found \(sortedChunks.count)/\(assetData.chunkOffsets.count) chunks\(missingCount > 0 ? " (⚠️ \(missingCount) missing)" : "")")
        
        return sortedChunks
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
