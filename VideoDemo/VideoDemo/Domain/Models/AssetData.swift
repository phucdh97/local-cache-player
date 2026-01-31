//
//  AssetData.swift
//  VideoDemo
//
//  Data models for video cache with range-based tracking
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation

/// Represents a cached byte range
class CachedRange: NSObject, NSCoding {
    @objc var offset: Int64 = 0
    @objc var length: Int64 = 0
    
    override init() {
        super.init()
    }
    
    init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
        super.init()
    }
    
    required init?(coder: NSCoder) {
        super.init()
        self.offset = coder.decodeInt64(forKey: "offset")
        self.length = coder.decodeInt64(forKey: "length")
    }
    
    func encode(with coder: NSCoder) {
        coder.encode(self.offset, forKey: "offset")
        coder.encode(self.length, forKey: "length")
    }
    
    /// Check if this range fully contains another range
    func contains(offset: Int64, length: Int64) -> Bool {
        return offset >= self.offset &&
               (offset + length) <= (self.offset + self.length)
    }
    
    /// Check if this range overlaps with another range
    func overlaps(with other: CachedRange) -> Bool {
        let thisEnd = self.offset + self.length
        let otherEnd = other.offset + other.length
        return !(self.offset >= otherEnd || other.offset >= thisEnd)
    }
    
    /// Check if this range is adjacent to another range
    func isAdjacentTo(_ other: CachedRange) -> Bool {
        return self.offset + self.length == other.offset ||
               other.offset + other.length == self.offset
    }
}

/// Content information metadata for cached video
class AssetDataContentInformation: NSObject, NSCoding {
    @objc var contentLength: Int64 = 0
    @objc var contentType: String = ""
    @objc var isByteRangeAccessSupported: Bool = false
    
    override init() {
        super.init()
    }
    
    required init?(coder: NSCoder) {
        super.init()
        self.contentLength = coder.decodeInt64(forKey: #keyPath(AssetDataContentInformation.contentLength))
        self.contentType = coder.decodeObject(forKey: #keyPath(AssetDataContentInformation.contentType)) as? String ?? ""
        self.isByteRangeAccessSupported = coder.decodeBool(forKey: #keyPath(AssetDataContentInformation.isByteRangeAccessSupported))
    }
    
    func encode(with coder: NSCoder) {
        coder.encode(self.contentLength, forKey: #keyPath(AssetDataContentInformation.contentLength))
        coder.encode(self.contentType, forKey: #keyPath(AssetDataContentInformation.contentType))
        coder.encode(self.isByteRangeAccessSupported, forKey: #keyPath(AssetDataContentInformation.isByteRangeAccessSupported))
    }
}

/// Container for cached video data and metadata with range tracking
class AssetData: NSObject, NSCoding {
    @objc var contentInformation: AssetDataContentInformation = AssetDataContentInformation()
    @objc var mediaData: Data = Data()  // Deprecated: kept for backward compatibility
    @objc var cachedRanges: [CachedRange] = []  // Track merged ranges for quick lookup
    @objc var chunkOffsets: [NSNumber] = []  // Track actual chunk offsets for retrieval
    
    override init() {
        super.init()
    }
    
    required init?(coder: NSCoder) {
        super.init()
        self.contentInformation = coder.decodeObject(forKey: #keyPath(AssetData.contentInformation)) as? AssetDataContentInformation ?? AssetDataContentInformation()
        self.mediaData = coder.decodeObject(forKey: #keyPath(AssetData.mediaData)) as? Data ?? Data()
        self.cachedRanges = coder.decodeObject(forKey: #keyPath(AssetData.cachedRanges)) as? [CachedRange] ?? []
        self.chunkOffsets = coder.decodeObject(forKey: #keyPath(AssetData.chunkOffsets)) as? [NSNumber] ?? []
    }
    
    func encode(with coder: NSCoder) {
        coder.encode(self.contentInformation, forKey: #keyPath(AssetData.contentInformation))
        coder.encode(self.mediaData, forKey: #keyPath(AssetData.mediaData))
        coder.encode(self.cachedRanges, forKey: #keyPath(AssetData.cachedRanges))
        coder.encode(self.chunkOffsets, forKey: #keyPath(AssetData.chunkOffsets))
    }
}
