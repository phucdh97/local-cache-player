//
//  AssetDataManager.swift
//  VideoDemo
//
//  Protocol for cache manager implementations
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation

/// Protocol for managing cached video data
/// Implementations can use different storage strategies (PINCache, FileHandle, etc.)
protocol AssetDataManager: NSObject {
    /// Retrieve cached asset data
    func retrieveAssetData() -> AssetData?
    
    /// Save content information (metadata) to cache
    func saveContentInformation(_ contentInformation: AssetDataContentInformation)
    
    /// Save downloaded data chunk to cache
    /// - Parameters:
    ///   - data: Downloaded data chunk
    ///   - offset: Byte offset where this data starts
    func saveDownloadedData(_ data: Data, offset: Int)
    
    /// Merge new downloaded data with existing cache if continuous
    /// - Parameters:
    ///   - from: Existing cached data
    ///   - with: New data to merge
    ///   - offset: Byte offset of new data
    /// - Returns: Merged data if continuous, nil otherwise
    func mergeDownloadedDataIfIsContinuted(from: Data, with: Data, offset: Int) -> Data?
}

extension AssetDataManager {
    /// Default implementation: Merge data only if continuous (sequential download)
    /// This ensures cache integrity by only appending data that follows existing data
    func mergeDownloadedDataIfIsContinuted(from: Data, with: Data, offset: Int) -> Data? {
        // Check if new data continues from where existing data ends
        // offset should be at or before the end of existing data
        // and the new data should extend beyond existing data
        if offset <= from.count && (offset + with.count) > from.count {
            let start = from.count - offset
            var data = from
            data.append(with.subdata(in: start..<with.count))
            return data
        }
        return nil
    }
}
