//
//  AssetDataManager.swift
//  VideoDemo
//
//  Protocol for cache manager implementations with range-based support
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation

/// Protocol for managing cached video data with range tracking
/// Implementations can use different storage strategies (PINCache, FileHandle, etc.)
protocol AssetDataManager: NSObject {
    /// Retrieve cached asset data
    func retrieveAssetData() -> AssetData?
    
    /// Save content information (metadata) to cache
    func saveContentInformation(_ contentInformation: AssetDataContentInformation)
    
    /// Save downloaded data chunk to cache at any offset
    /// - Parameters:
    ///   - data: Downloaded data chunk
    ///   - offset: Byte offset where this data starts
    func saveDownloadedData(_ data: Data, offset: Int)
    
    // MARK: - Range-Based Query Methods
    
    /// Check if a specific byte range is fully cached
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes
    /// - Returns: true if the entire range is cached
    func isRangeCached(offset: Int64, length: Int) -> Bool
    
    /// Retrieve data for a specific byte range
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes to retrieve
    /// - Returns: Data if fully cached, nil if any gaps exist
    func retrieveDataInRange(offset: Int64, length: Int) -> Data?
    
    /// Retrieve whatever data is available in a range (may be partial)
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes to retrieve
    /// - Returns: Available data, may be less than requested
    func retrievePartialData(offset: Int64, length: Int) -> Data?
    
    /// Get all cached ranges
    /// - Returns: Array of cached ranges
    func getCachedRanges() -> [CachedRange]
}

extension AssetDataManager {
    /// Default implementation: Check if range is fully covered by cached ranges
    func isRangeCached(offset: Int64, length: Int) -> Bool {
        guard let assetData = retrieveAssetData() else { return false }
        
        for range in assetData.cachedRanges {
            if range.contains(offset: offset, length: Int64(length)) {
                return true
            }
        }
        
        return false
    }
    
    /// Default implementation: Return partial data (delegates to retrieveDataInRange)
    func retrievePartialData(offset: Int64, length: Int) -> Data? {
        return retrieveDataInRange(offset: offset, length: length)
    }
    
    /// Default implementation: Get cached ranges from asset data
    func getCachedRanges() -> [CachedRange] {
        return retrieveAssetData()?.cachedRanges ?? []
    }
}
