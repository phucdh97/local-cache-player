//
//  FileHandleAssetRepository.swift
//  VideoDemo
//
//  Production-ready asset repository using FileHandle + Swift Actor
//  Suitable for large videos (100MB+) without memory bloat
//  Thread-safe through Actor isolation
//

import Foundation

/// Actor-based asset repository for production use
/// Uses FileHandle for efficient streaming without loading entire video
/// Thread-safe through Swift Actor isolation (compiler-enforced)
/// Requires iOS 17+ (app minimum deployment target)
actor FileHandleAssetRepository: AssetDataRepositoryAsync {
    
    // MARK: - Properties
    
    private let storage: FileHandleStorage
    private let cacheKey: String
    
    // Task caching to prevent duplicate reads (handles reentrancy)
    private var inFlightReads: [String: Task<Data?, Error>] = [:]
    
    // Cached metadata (in-memory for quick access)
    private var cachedMetadata: AssetData?
    
    // MARK: - Initialization
    
    init(cacheKey: String, cacheDirectory: URL) throws {
        self.cacheKey = cacheKey
        self.storage = try FileHandleStorage(cacheKey: cacheKey, cacheDirectory: cacheDirectory)
    }
    
    // MARK: - AssetDataRepositoryAsync Protocol
    
    func retrieveAssetData() async -> AssetData? {
        // Return cached metadata if available
        if let cached = cachedMetadata {
            return cached
        }
        
        // Load from disk
        do {
            let metadata = try await storage.loadMetadata()
            cachedMetadata = metadata
            
            if let metadata = metadata {
                let totalCached = metadata.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
                print("📦 [FileHandle] Loaded metadata for \(cacheKey): \(formatBytes(totalCached)) in \(metadata.cachedRanges.count) range(s)")
            } else {
                print("📦 [FileHandle] No metadata found for \(cacheKey)")
            }
            
            return metadata
        } catch {
            print("❌ [FileHandle] Failed to load metadata: \(error)")
            return nil
        }
    }
    
    func saveContentInformation(_ contentInformation: AssetDataContentInformation) async {
        var assetData = await retrieveAssetData() ?? AssetData()
        assetData.contentInformation = contentInformation
        
        do {
            try await storage.saveMetadata(assetData)
            cachedMetadata = assetData
            print("📋 [FileHandle] Content info saved: \(formatBytes(contentInformation.contentLength))")
        } catch {
            print("❌ [FileHandle] Failed to save content info: \(error)")
        }
    }
    
    func saveDownloadedData(_ data: Data, offset: Int) async {
        var assetData = await retrieveAssetData() ?? AssetData()
        
        guard assetData.contentInformation.contentLength > 0 else {
            print("⚠️ [FileHandle] No content info, skipping save")
            return
        }
        
        do {
            // Write data to file at specific offset
            try await storage.writeData(data, at: Int64(offset))
            print("💾 [FileHandle] Wrote \(formatBytes(data.count)) at offset \(formatBytes(Int64(offset)))")
            
            // Update metadata
            let offsetNumber = NSNumber(value: offset)
            if !assetData.chunkOffsets.contains(offsetNumber) {
                assetData.chunkOffsets.append(offsetNumber)
                assetData.chunkOffsets.sort { $0.int64Value < $1.int64Value }
            }
            
            // Update cached ranges
            let newRange = CachedRange(offset: Int64(offset), length: Int64(data.count))
            assetData.cachedRanges = mergeRanges(assetData.cachedRanges + [newRange])
            
            // Save metadata
            try await storage.saveMetadata(assetData)
            cachedMetadata = assetData
            
            let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
            let percentage = assetData.contentInformation.contentLength > 0
                ? (Double(totalCached) / Double(assetData.contentInformation.contentLength)) * 100.0
                : 0.0
            
            print("✅ [FileHandle] Chunk saved: \(assetData.cachedRanges.count) range(s), \(formatBytes(totalCached)) (\(String(format: "%.1f", percentage))%)")
            
        } catch {
            print("❌ [FileHandle] Failed to save data: \(error)")
        }
    }
    
    func isRangeCached(offset: Int64, length: Int) async -> Bool {
        guard let assetData = await retrieveAssetData() else {
            return false
        }
        
        let requestEnd = offset + Int64(length)
        
        for range in assetData.cachedRanges {
            let rangeEnd = range.offset + range.length
            if offset >= range.offset && requestEnd <= rangeEnd {
                return true
            }
        }
        
        return false
    }
    
    func retrieveDataInRange(offset: Int64, length: Int) async -> Data? {
        // Check if range is cached
        guard await isRangeCached(offset: offset, length: length) else {
            print("📦 [FileHandle] Range not fully cached: offset=\(formatBytes(offset)), length=\(formatBytes(Int64(length)))")
            return nil
        }
        
        // Check for in-flight read to prevent duplicate work
        let taskKey = "\(offset)-\(length)"
        if let existingTask = inFlightReads[taskKey] {
            print("🔄 [FileHandle] Reusing in-flight read for \(taskKey)")
            return try? await existingTask.value
        }
        
        // Create new read task and cache it BEFORE await
        let task = Task<Data?, Error> {
            try await storage.readData(offset: offset, length: length)
        }
        
        inFlightReads[taskKey] = task
        
        defer {
            // Clean up after read completes
            inFlightReads.removeValue(forKey: taskKey)
        }
        
        do {
            let data = try await task.value
            print("📥 [FileHandle] Read \(formatBytes(Int64(data?.count ?? 0))) from offset \(formatBytes(offset))")
            return data
        } catch {
            print("❌ [FileHandle] Failed to read data: \(error)")
            return nil
        }
    }
    
    func retrievePartialData(offset: Int64, length: Int) async -> Data? {
        // For FileHandle implementation, return whatever is available
        return await retrieveDataInRange(offset: offset, length: length)
    }
    
    func getCachedRanges() async -> [CachedRange] {
        return await retrieveAssetData()?.cachedRanges ?? []
    }
    
    // MARK: - Helper Methods
    
    /// Merge overlapping or adjacent ranges
    private func mergeRanges(_ ranges: [CachedRange]) -> [CachedRange] {
        guard !ranges.isEmpty else { return [] }
        
        let sorted = ranges.sorted { $0.offset < $1.offset }
        var merged: [CachedRange] = []
        var current = sorted[0]
        
        for range in sorted.dropFirst() {
            let currentEnd = current.offset + current.length
            let rangeEnd = range.offset + range.length
            
            if range.offset <= currentEnd {
                // Overlapping or adjacent, merge
                let newEnd = max(currentEnd, rangeEnd)
                current = CachedRange(offset: current.offset, length: newEnd - current.offset)
            } else {
                // Gap found, save current and start new
                merged.append(current)
                current = range
            }
        }
        
        merged.append(current)
        return merged
    }
}

// MARK: - Helper Functions (removed - use global formatBytes from ByteFormatter.swift)

