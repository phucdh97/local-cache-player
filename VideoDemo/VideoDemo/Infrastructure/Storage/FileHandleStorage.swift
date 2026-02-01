//
//  FileHandleStorage.swift
//  VideoDemo
//
//  FileHandle-based storage for efficient video caching
//  Streams data to/from disk without loading entire video into memory
//  Production-ready for large videos (100MB+)
//

import Foundation

/// FileHandle-based storage for video data and metadata
/// Uses separate files for video data and metadata (JSON)
/// Thread-safe through serial queue
@available(iOS 13.0, *)
class FileHandleStorage {
    
    // MARK: - Properties
    
    private let videoFileURL: URL
    private let metadataFileURL: URL
    private let storageQueue: DispatchQueue
    private var fileHandle: FileHandle?
    
    // MARK: - Initialization
    
    /// Initialize storage for a specific video
    /// - Parameters:
    ///   - cacheKey: Unique identifier for the video
    ///   - cacheDirectory: Directory to store cache files
    init(cacheKey: String, cacheDirectory: URL) throws {
        // Create unique file paths
        let safeKey = cacheKey.replacingOccurrences(of: "/", with: "_")
        self.videoFileURL = cacheDirectory.appendingPathComponent("\(safeKey).video")
        self.metadataFileURL = cacheDirectory.appendingPathComponent("\(safeKey).metadata.json")
        
        // Serial queue for thread safety
        self.storageQueue = DispatchQueue(label: "com.videodemo.filehandlestorage.\(safeKey)", qos: .userInitiated)
        
        // Create cache directory if needed
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Create video file if it doesn't exist
        if !FileManager.default.fileExists(atPath: videoFileURL.path) {
            FileManager.default.createFile(atPath: videoFileURL.path, contents: nil)
        }
        
        // Open file handle for reading and writing
        self.fileHandle = try FileHandle(forUpdating: videoFileURL)
    }
    
    deinit {
        try? fileHandle?.close()
    }
    
    // MARK: - Async Operations
    
    /// Read data from specific offset asynchronously
    /// Uses DispatchQueue to avoid blocking Swift's cooperative threads
    func readData(offset: Int64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            storageQueue.async { [weak self] in
                guard let self = self, let handle = self.fileHandle else {
                    continuation.resume(throwing: StorageError.fileHandleNotAvailable)
                    return
                }
                
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    let data = handle.readData(ofLength: length)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Write data at specific offset asynchronously
    func writeData(_ data: Data, at offset: Int64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storageQueue.async { [weak self] in
                guard let self = self, let handle = self.fileHandle else {
                    continuation.resume(throwing: StorageError.fileHandleNotAvailable)
                    return
                }
                
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    handle.write(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Get file size asynchronously
    func getFileSize() async throws -> Int64 {
        try await withCheckedThrowingContinuation { continuation in
            storageQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: StorageError.fileHandleNotAvailable)
                    return
                }
                
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: self.videoFileURL.path)
                    let size = attributes[.size] as? Int64 ?? 0
                    continuation.resume(returning: size)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Metadata Operations
    
    /// Load metadata from JSON file
    func loadMetadata() async throws -> AssetData? {
        try await withCheckedThrowingContinuation { continuation in
            storageQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
                guard FileManager.default.fileExists(atPath: self.metadataFileURL.path) else {
                    continuation.resume(returning: nil)
                    return
                }
                
                do {
                    let data = try Data(contentsOf: self.metadataFileURL)
                    let decoder = JSONDecoder()
                    let metadata = try decoder.decode(AssetMetadata.self, from: data)
                    let assetData = metadata.toAssetData()
                    continuation.resume(returning: assetData)
                } catch {
                    print("⚠️ Failed to load metadata: \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    
    /// Save metadata to JSON file
    func saveMetadata(_ assetData: AssetData) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storageQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: StorageError.fileHandleNotAvailable)
                    return
                }
                
                do {
                    let metadata = AssetMetadata.from(assetData)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .prettyPrinted
                    let data = try encoder.encode(metadata)
                    try data.write(to: self.metadataFileURL, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Delete all files for this asset
    func deleteAll() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            storageQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: StorageError.fileHandleNotAvailable)
                    return
                }
                
                do {
                    try self.fileHandle?.close()
                    self.fileHandle = nil
                    
                    try FileManager.default.removeItem(at: self.videoFileURL)
                    
                    if FileManager.default.fileExists(atPath: self.metadataFileURL.path) {
                        try FileManager.default.removeItem(at: self.metadataFileURL)
                    }
                    
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Storage Error

enum StorageError: Error {
    case fileHandleNotAvailable
    case readFailed
    case writeFailed
    case metadataNotFound
}

// MARK: - AssetMetadata (Codable version of AssetData)

/// JSON-serializable version of AssetData
/// Used for metadata persistence in FileHandle-based storage
struct AssetMetadata: Codable {
    let contentLength: Int64
    let contentType: String
    let isByteRangeAccessSupported: Bool
    let cachedRanges: [CachedRangeMetadata]
    let chunkOffsets: [Int64]
    
    struct CachedRangeMetadata: Codable {
        let offset: Int64
        let length: Int64
    }
    
    /// Convert to AssetData for compatibility
    func toAssetData() -> AssetData {
        let assetData = AssetData()
        
        let contentInfo = AssetDataContentInformation()
        contentInfo.contentLength = contentLength
        contentInfo.contentType = contentType
        contentInfo.isByteRangeAccessSupported = isByteRangeAccessSupported
        assetData.contentInformation = contentInfo
        
        assetData.cachedRanges = cachedRanges.map {
            CachedRange(offset: $0.offset, length: $0.length)
        }
        
        assetData.chunkOffsets = chunkOffsets.map { NSNumber(value: $0) }
        
        return assetData
    }
    
    /// Create from AssetData
    static func from(_ assetData: AssetData) -> AssetMetadata {
        return AssetMetadata(
            contentLength: assetData.contentInformation.contentLength,
            contentType: assetData.contentInformation.contentType,
            isByteRangeAccessSupported: assetData.contentInformation.isByteRangeAccessSupported,
            cachedRanges: assetData.cachedRanges.map {
                CachedRangeMetadata(offset: $0.offset, length: $0.length)
            },
            chunkOffsets: assetData.chunkOffsets.map { $0.int64Value }
        )
    }
}
