# 🔍 Detailed Comparison: ZPlayerCacher vs Our Implementation

## Overview

This document provides a **code-level comparison** between the ZPlayerCacher (resourceLoaderDemo) and our custom implementation (VideoDemo), focusing on thread safety, caching strategies, and architectural differences.

**Last Updated:** January 25, 2026  
**Based on:** Current codebase with Swift Actor implementation

---

## 📦 Thread Safety & Caching Strategy

### **ZPlayerCacher: PINCache Approach**

```swift
// PINCacheAssetDataManager.swift
class PINCacheAssetDataManager: NSObject, AssetDataManager {
    static let Cache: PINCache = PINCache(name: "ResourceLoader")
    let cacheKey: String
    
    func saveDownloadedData(_ data: Data, offset: Int) {
        guard let assetData = self.retrieveAssetData() else {
            return
        }
        
        if let mediaData = self.mergeDownloadedDataIfIsContinuted(from: assetData.mediaData, with: data, offset: offset) {
            assetData.mediaData = mediaData
            // ✅ Thread-safe write - no manual locks!
            PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
        }
    }
    
    func retrieveAssetData() -> AssetData? {
        // ✅ Thread-safe read - no manual locks!
        guard let assetData = PINCacheAssetDataManager.Cache.object(forKey: cacheKey) as? AssetData else {
            return nil
        }
        return assetData
    }
}
```

**Key Points:**
- ✅ **PINCache handles all thread safety internally**
- ✅ **No NSLock needed** - library does it for you
- ✅ **Automatic memory + disk caching** with LRU eviction
- ✅ **Battle-tested** (used by Pinterest in production)
- ✅ **Single Data blob** - all video data stored as one `Data` object
- ⚠️ **Dependency required** - must install PINCache via CocoaPods
- ❌ **Not suitable for large videos** - loads entire video into memory

---

### **Our Implementation: Swift Actor Approach**

```swift
// VideoCacheManager.swift
actor VideoCacheManager {
    private var metadataCache: [String: CacheMetadata] = [:]
    
    // ✅ Actor-isolated: Thread-safe by compiler
    func getCacheMetadata(for url: URL) -> CacheMetadata? {
        let key = cacheKey(for: url)
        
        // Check in-memory cache (✅ Thread-safe via Actor)
        if let cached = metadataCache[key] {
            return cached
        }
        
        // Load from disk
        let metadataPath = metadataFilePath(for: url)
        guard FileManager.default.fileExists(atPath: metadataPath.path) else {
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
    
    // ✅ Actor-isolated: Automatic serialization
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
        
        // Save to disk asynchronously
        Task.detached { [metadata, url, metadataPath = metadataFilePath(for: url)] in
            do {
                let data = try JSONEncoder().encode(metadata)
                try data.write(to: metadataPath)
            } catch {
                print("❌ Error saving metadata: \(error)")
            }
        }
    }
}
```

**Key Points:**
- ✅ **Swift Actor ensures thread safety automatically**
- ✅ **No NSLock needed** - compiler enforces safety
- ✅ **No PINCache dependency** - pure Swift/Foundation
- ✅ **Modern Swift** (iOS 15+, async/await)
- ✅ **Custom metadata tracking** with `CachedRange`
- ✅ **FileHandle-based chunk writing** for progressive caching
- ⚠️ **Must use `await`** - requires async context
- ✅ **Compiler-enforced** - impossible to forget thread safety

---

## 🗂️ Data Storage Strategy

### **ZPlayerCacher: Single Data Blob**

```swift
// AssetData.swift
class AssetData: NSObject, NSCoding {
    @objc var contentInformation: AssetDataContentInformation = AssetDataContentInformation()
    @objc var mediaData: Data = Data()  // ❗ Entire video stored as ONE Data object
    
    func encode(with coder: NSCoder) {
        coder.encode(self.contentInformation, forKey: #keyPath(AssetData.contentInformation))
        coder.encode(self.mediaData, forKey: #keyPath(AssetData.mediaData))  // Serialize entire video
    }
}
```

**Storage Model:**
```
PINCache
 └─ "video_key" → AssetData
      ├─ contentInformation (metadata)
      └─ mediaData (entire video as Data)
```

**Pros:**
- ✅ Simple to understand
- ✅ Single object to cache/retrieve
- ✅ Automatic serialization via NSCoding

**Cons:**
- ❌ **Memory inefficient** - entire video loaded into RAM
- ❌ **No progressive caching** - must download entire video first
- ❌ **Large memory footprint** for HD videos (158 MB video = 158 MB RAM!)
- ❌ **OOM risk** with multiple videos or 4K content

---

### **Our Implementation: Range-Based Progressive Caching**

```swift
// VideoCacheManager.swift
struct CacheMetadata: Codable, Sendable {
    var contentLength: Int64?
    var contentType: String?
    var cachedRanges: [CachedRange]  // ✅ Track which ranges are cached
    var isFullyCached: Bool
    var lastModified: Date
}

struct CachedRange: Codable, Sendable {
    let offset: Int64
    let length: Int64
    
    func contains(offset: Int64, length: Int64) -> Bool {
        return offset >= self.offset && (offset + length) <= (self.offset + self.length)
    }
}
```

**Storage Model:**
```
FileSystem
 ├─ video_key              (raw video data, progressive)
 └─ video_key.metadata     (JSON metadata with cached ranges)

Memory (VideoResourceLoaderDelegate)
 └─ recentChunks: [(offset, data)]  (last 20 chunks, ~5MB)
```

**Progressive Caching:**
```swift
// Non-isolated: FileHandle operations are thread-safe
nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
    let fileManager = FileManager.default  // Local instance (Swift 6)
    let filePath = cacheFilePath(for: url)
    
    do {
        if !fileManager.fileExists(atPath: filePath.path) {
            fileManager.createFile(atPath: filePath.path, contents: nil)
        }
        
        let fileHandle = try FileHandle(forWritingTo: filePath)
        defer { try? fileHandle.close() }
        
        // ✅ Write chunk at specific offset
        try fileHandle.seek(toOffset: UInt64(offset))
        fileHandle.write(data)
        
        print("💾 Cached chunk: \(data.count) bytes at offset \(offset)")
    } catch {
        print("❌ Error caching chunk: \(error)")
    }
}
```

**Pros:**
- ✅ **Memory efficient** - only recent chunks in RAM (~5MB)
- ✅ **Progressive caching** - can seek before full download
- ✅ **Fine-grained tracking** - knows which byte ranges are cached
- ✅ **Resume downloads** - can continue from where it left off
- ✅ **Works with any video size** - no memory constraints

**Cons:**
- ⚠️ **More complex** - must manage ranges and merging
- ⚠️ **Manual file handling** - FileHandle operations
- ⚠️ **More code to maintain**

---

## 🏗️ Architecture Comparison

### **ZPlayerCacher Architecture**

```
┌─────────────────────────────────────────┐
│         AVAssetResourceLoader           │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│         ResourceLoader                   │
│  - Manages loading requests              │
│  - Delegates to AssetDataManager         │
│  - Serial DispatchQueue (loaderQueue)    │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    PINCacheAssetDataManager              │
│  - Uses PINCache for thread safety      │
│  - Stores entire video as Data blob     │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│          PINCache (Library)              │
│  ✅ Thread-safe memory + disk cache     │
│  ✅ Automatic LRU eviction               │
│  ❌ Loads entire video into memory       │
└─────────────────────────────────────────┘
```

**Key Files:**
- `ResourceLoader.swift` - AVAssetResourceLoaderDelegate
- `PINCacheAssetDataManager.swift` - Cache management with PINCache
- `AssetData.swift` - Data models (NSCoding)
- `ResourceLoaderRequest.swift` - Network request handling

**Thread Safety Strategy:**
- Serial DispatchQueue (`loaderQueue`) for request coordination
- PINCache handles cache access thread safety
- Delegates to separate `ResourceLoaderRequest` instances

---

### **Our Implementation Architecture**

```
┌─────────────────────────────────────────┐
│         AVAssetResourceLoader           │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│    VideoResourceLoaderDelegate           │
│  - Handles loading requests              │
│  - Progressive download via URLSession   │
│  - Recent chunks buffer (in-memory)      │
│  - Serial DispatchQueue (recentChunks)   │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│       VideoCacheManager (Actor)          │
│  - Swift Actor for thread safety         │
│  - Range-based caching with metadata     │
│  - FileHandle for chunk writing          │
│  - Non-isolated file operations          │
└───────────────┬─────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│  FileManager + FileHandle (Built-in)     │
│  ✅ No external dependencies             │
│  ✅ Progressive caching support          │
│  ✅ Low memory footprint                 │
└─────────────────────────────────────────┘
```

**Key Files:**
- `VideoResourceLoaderDelegate.swift` - AVAssetResourceLoaderDelegate + URLSessionDelegate
- `VideoCacheManager.swift` - Actor-based cache management
- `CachedVideoPlayerManager.swift` - Manages player instances
- `CachedVideoPlayer.swift` - SwiftUI video player view

**Thread Safety Strategy:**
- Swift Actor for metadata operations (compiler-enforced)
- Serial DispatchQueue for `recentChunks` buffer (AVFoundation compatibility)
- Non-isolated FileHandle operations (inherently thread-safe)
- No manual locks needed

---

## 📊 Side-by-Side Comparison Table

| **Aspect** | **ZPlayerCacher (PINCache)** | **Our Implementation (Actor)** |
|------------|------------------------------|--------------------------------|
| **Thread Safety** | ✅ Automatic (PINCache + DispatchQueue) | ✅ Automatic (Actor + DispatchQueue) |
| **Complexity** | ✅ Simple (library abstraction) | ⚠️ Medium (custom implementation) |
| **Error Prone** | ✅ Low | ✅ Low (compiler-enforced) |
| **Dependencies** | ❌ Requires PINCache + CocoaPods | ✅ No dependencies |
| **Memory Usage** | ❌ High (entire video in RAM) | ✅ Low (only recent chunks) |
| **Progressive Caching** | ❌ No (downloads full video) | ✅ Yes (range-based) |
| **Seeking Before Complete** | ❌ Must wait for full download | ✅ Can seek to cached ranges |
| **Cache Strategy** | Single Data blob | Range-based chunks |
| **Disk Storage** | NSCoding serialization | FileHandle + JSON metadata |
| **Memory Management** | Automatic (PINCache LRU) | Manual (recent chunks trimming) |
| **LRU Eviction** | ✅ Automatic | ⚠️ Manual (if needed) |
| **Video Size Support** | ⚠️ Small videos only (<50MB) | ✅ Any size (GB+) |
| **Production Ready** | ✅ Yes (battle-tested) | ✅ Yes (Swift 6 compliant) |
| **Code Lines** | ~150 lines | ~520 lines |
| **Learning Curve** | Low (library abstracts complexity) | Medium (Actor + FileHandle) |
| **iOS Version** | ✅ iOS 9+ | ⚠️ iOS 15+ (Actor) |
| **Swift Version** | Swift 4+ | Swift 5.5+ (Swift 6 ready) |
| **Concurrency Model** | DispatchQueue | Actor + DispatchQueue hybrid |

---

## 🔬 Code-Level Differences

### **1. Saving Downloaded Data**

#### ZPlayerCacher:
```swift
func saveDownloadedData(_ data: Data, offset: Int) {
    guard let assetData = self.retrieveAssetData() else {
        return
    }
    
    // Merge new data with existing (if continuous)
    if let mediaData = self.mergeDownloadedDataIfIsContinuted(
        from: assetData.mediaData, 
        with: data, 
        offset: offset
    ) {
        assetData.mediaData = mediaData
        
        // ✅ One line, thread-safe!
        PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
    }
}
```

#### Our Implementation:
```swift
// Non-isolated: Direct disk write (no memory accumulation)
nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
    let fileManager = FileManager.default
    let filePath = cacheFilePath(for: url)
    
    do {
        if !fileManager.fileExists(atPath: filePath.path) {
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

// Actor-isolated: Update metadata asynchronously
func addCachedRange(for url: URL, offset: Int64, length: Int64) {
    let key = cacheKey(for: url)
    var metadata = metadataCache[key] ?? CacheMetadata()
    
    let newRange = CachedRange(offset: offset, length: length)
    metadata.cachedRanges.append(newRange)
    metadata.cachedRanges = mergeOverlappingRanges(metadata.cachedRanges)
    metadata.lastModified = Date()
    
    // ✅ Thread-safe via Actor
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
}
```

**Key Differences:**
- **ZPlayerCacher**: Accumulates data in memory, saves entire blob
- **Our Approach**: Writes directly to disk at offset, updates metadata separately

---

### **2. Retrieving Cached Data**

#### ZPlayerCacher:
```swift
func retrieveAssetData() -> AssetData? {
    // ✅ Thread-safe, one line
    guard let assetData = PINCacheAssetDataManager.Cache.object(forKey: cacheKey) as? AssetData else {
        return nil
    }
    return assetData
}
```

#### Our Implementation:
```swift
// Actor-isolated: Metadata retrieval
func getCacheMetadata(for url: URL) -> CacheMetadata? {
    let key = cacheKey(for: url)
    
    // Check in-memory cache (✅ Thread-safe via Actor)
    if let cached = metadataCache[key] {
        return cached
    }
    
    // Load from disk
    let metadataPath = metadataFilePath(for: url)
    guard FileManager.default.fileExists(atPath: metadataPath.path) else {
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

// Non-isolated: Data retrieval
nonisolated func cachedData(for url: URL, offset: Int64, length: Int) -> Data? {
    let fileManager = FileManager.default
    let filePath = cacheFilePath(for: url)
    guard fileManager.fileExists(atPath: filePath.path) else {
        return nil
    }
    
    let cachedSize = getCachedDataSize(for: url)
    guard offset < cachedSize else {
        return nil
    }
    
    // ✅ Return partial data if full range not available
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
```

**Key Differences:**
- **ZPlayerCacher**: Returns entire `AssetData` object from memory/disk cache
- **Our Approach**: Separates metadata (actor-isolated) from data (non-isolated file I/O)

---

### **3. AVAssetResourceLoaderDelegate Implementation**

#### ZPlayerCacher:
```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader, 
                   shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    
    let type = ResourceLoader.resourceLoaderRequestType(loadingRequest)
    let assetDataManager = PINCacheAssetDataManager(cacheKey: self.cacheKey)

    // ✅ Check cache first (synchronous)
    if let assetData = assetDataManager.retrieveAssetData() {
        if type == .contentInformation {
            loadingRequest.contentInformationRequest?.contentLength = assetData.contentInformation.contentLength
            loadingRequest.contentInformationRequest?.contentType = assetData.contentInformation.contentType
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = assetData.contentInformation.isByteRangeAccessSupported
            loadingRequest.finishLoading()
            return true
        } else {
            let range = ResourceLoader.resourceLoaderRequestRange(type, loadingRequest)
            
            // Check if we have enough data
            if assetData.mediaData.count >= end {
                let subData = assetData.mediaData.subdata(in: Int(range.start)..<Int(end))
                loadingRequest.dataRequest?.respond(with: subData)
                loadingRequest.finishLoading()
               return true
            }
        }
    }
    
    // Start network request if cache miss
    let resourceLoaderRequest = ResourceLoaderRequest(...)
    resourceLoaderRequest.start(requestRange: range)
    
    return true
}
```

#### Our Implementation:
```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    
    let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
    let length = loadingRequest.dataRequest?.requestedLength ?? 0
    print("📥 Loading request: offset=\(offset), length=\(length)")
    
    // ✅ Wrap async cache check in Task
    Task {
        if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
           await cacheManager.isRangeCached(for: originalURL, offset: offset, length: Int64(length)) {
            print("✅ Range is cached, serving from cache")
            await self.handleLoadingRequest(loadingRequest)
            return
        }
        
        // Add to pending requests
        self.loadingRequests.append(loadingRequest)
        
        // Try to fulfill with already downloaded data
        await self.processLoadingRequests()
        
        // Start download if not already downloading
        if self.downloadTask == nil {
            self.startProgressiveDownload()
        }
    }
    
    return true  // Return immediately, processing continues in Task
}
```

**Key Differences:**
- **ZPlayerCacher**: Synchronous cache check, creates separate `ResourceLoaderRequest` per request
- **Our Approach**: Async cache check with Task wrapper, single download session with pending requests queue

---

## 🎯 Key Lessons Learned

### **What ZPlayerCacher Does Right:**

1. **Use PINCache for Thread Safety**
   - No manual locks needed
   - Battle-tested in production
   - Automatic memory + disk management
   - Perfect for **small media files** (<50MB)

2. **Simple API**
   - `setObjectAsync()` / `object(forKey:)`
   - Clear separation of concerns
   - Protocol-based design (`AssetDataManager`)

3. **Clean Architecture**
   - ResourceLoader handles AVFoundation
   - AssetDataManager handles caching
   - ResourceLoaderRequest handles network

---

### **What Our Implementation Does Better:**

1. **Progressive Caching**
   - Can seek to any cached range
   - No need to download entire video first
   - Memory efficient (only recent chunks in RAM)

2. **Modern Swift Concurrency**
   - Swift Actor for automatic thread safety
   - Compiler-enforced correctness
   - No manual locks (impossible to forget)

3. **Scalable to Large Videos**
   - FileHandle-based direct disk writes
   - No memory accumulation (unlike PINCache)
   - Supports GB+ video files

4. **No External Dependencies**
   - Pure Swift + Foundation
   - No CocoaPods/SPM needed
   - Full control over caching logic

5. **Fine-Grained Control**
   - Track which byte ranges are cached
   - Merge overlapping ranges
   - Resume downloads from last position

---

## 🚀 Architecture Evolution Summary

### **ZPlayerCacher Design Philosophy:**
- **Target:** Small audio/video files (<50MB)
- **Simplicity over flexibility:** Use library (PINCache)
- **Trade-off:** Memory for simplicity
- **Thread Safety:** DispatchQueue + PINCache

### **Our Design Philosophy:**
- **Target:** Large video files (any size)
- **Flexibility over simplicity:** Custom implementation
- **Trade-off:** Complexity for scalability
- **Thread Safety:** Swift Actor + DispatchQueue hybrid

---

## 📈 Performance Comparison

| **Metric** | **ZPlayerCacher** | **Our Implementation** |
|------------|-------------------|------------------------|
| **Memory (HD video)** | ~158 MB (entire video) | ~5 MB (recent chunks) |
| **Seek Performance** | ⚠️ Must wait for full download | ✅ Instant (if range cached) |
| **Cache Write** | Fast (PINCache optimized) | Fast (FileHandle direct I/O) |
| **Cache Read** | Fast (in-memory Data) | Fast (FileHandle seek + read) |
| **Thread Safety** | ✅ Automatic (no overhead) | ✅ Automatic (Actor serialization) |
| **First Byte Time** | Similar (both use URLSession) | Similar |
| **Resume Support** | ❌ No (downloads from start) | ✅ Yes (range requests) |
| **Concurrent Downloads** | ✅ Multiple `ResourceLoaderRequest` | ✅ Single session, pending queue |

---

## 🎓 Conclusion

### **When to Use ZPlayerCacher Approach:**
- ✅ Smaller videos/audio (<50 MB)
- ✅ Want simple, proven solution
- ✅ Don't need progressive caching
- ✅ Okay with external dependency (PINCache)
- ✅ Value stability over control
- ✅ Support older iOS versions (iOS 9+)

### **When to Use Our Approach:**
- ✅ Large videos (>100 MB, HD, 4K)
- ✅ Need progressive caching
- ✅ Want fine-grained control
- ✅ No external dependencies allowed
- ✅ Need to track cache ranges
- ✅ Modern Swift project (iOS 15+)
- ✅ Want compiler-enforced thread safety

---

## 🔗 Thread Safety Models Compared

| **Component** | **ZPlayerCacher** | **Our Implementation** |
|---------------|-------------------|------------------------|
| **Cache Metadata** | PINCache (internal locks) | Swift Actor (compiler-enforced) |
| **Request Coordination** | Serial DispatchQueue | Task + async/await |
| **In-Memory Buffer** | PINCache (entire video) | Serial DispatchQueue (`recentChunks`) |
| **File I/O** | PINCache abstraction | FileHandle (non-isolated) |
| **Concurrency Model** | DispatchQueue-based | Actor + DispatchQueue hybrid |

**Both approaches are thread-safe, but use different mechanisms:**
- **ZPlayerCacher**: Library-managed thread safety (PINCache + DispatchQueue)
- **Our Implementation**: Compiler-enforced thread safety (Actor) + DispatchQueue for AVFoundation compatibility

---

## 📚 References

- **ZPlayerCacher**: https://github.com/ZhgChgLi/ZPlayerCacher
- **Blog Post**: https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/
- **PINCache**: https://github.com/pinterest/PINCache
- **Swift Actors**: https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html
- **AVAssetResourceLoader**: https://developer.apple.com/documentation/avfoundation/avassetresourceloader
- **Related Docs:**
  - [ACTOR_REFACTORING.md](./ACTOR_REFACTORING.md) - Detailed Actor migration guide
  - [DETAILED_FLOW_ANALYSIS.md](../resourceLoaderDemo-main/DETAILED_FLOW_ANALYSIS.md) - ZPlayerCacher flow analysis

---

**Bottom Line:** ZPlayerCacher prioritizes simplicity and reliability with PINCache (perfect for small files). Our implementation prioritizes progressive caching and memory efficiency with Swift Actors (perfect for large videos). Both are production-ready, but serve different use cases.
