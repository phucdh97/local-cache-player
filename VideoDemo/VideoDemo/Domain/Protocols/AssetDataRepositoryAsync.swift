//
//  AssetDataRepositoryAsync.swift
//  VideoDemo
//
//  Async protocol for asset data repository with production-ready FileHandle support
//  Migration from sync PINCache to async FileHandle-based storage
//

import Foundation

/// Async protocol for managing cached video data with range tracking
/// Implementations use FileHandle for efficient streaming without memory bloat
/// All operations are non-blocking and safe for any thread
/// Requires iOS 17+ (app minimum deployment target)
protocol AssetDataRepositoryAsync: AnyObject {
    /// Retrieve cached asset metadata asynchronously
    /// - Returns: Asset metadata if cached, nil otherwise
    func retrieveAssetData() async -> AssetData?
    
    /// Save content information (metadata) to cache
    /// - Parameter contentInformation: Video metadata (size, type, etc.)
    func saveContentInformation(_ contentInformation: AssetDataContentInformation) async
    
    /// Save downloaded data chunk to cache at specific offset
    /// - Parameters:
    ///   - data: Downloaded data chunk
    ///   - offset: Byte offset where this data starts
    func saveDownloadedData(_ data: Data, offset: Int) async
    
    // MARK: - Range-Based Query Methods
    
    /// Check if a specific byte range is fully cached
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes
    /// - Returns: true if the entire range is cached
    func isRangeCached(offset: Int64, length: Int) async -> Bool
    
    /// Retrieve data for a specific byte range
    /// Uses FileHandle seek + read for efficient random access
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes to retrieve
    /// - Returns: Data if fully cached, nil if any gaps exist
    func retrieveDataInRange(offset: Int64, length: Int) async -> Data?
    
    /// Retrieve whatever data is available in a range (may be partial)
    /// - Parameters:
    ///   - offset: Starting byte offset
    ///   - length: Number of bytes to retrieve
    /// - Returns: Available data, may be less than requested
    func retrievePartialData(offset: Int64, length: Int) async -> Data?
    
    /// Get all cached ranges
    /// - Returns: Array of cached ranges
    func getCachedRanges() async -> [CachedRange]
}
