# Async vs Sync Cache Operations Analysis

**Project:** VideoDemo
**Date:** January 2026
**Purpose:** Technical analysis of cache operation patterns and production recommendations

---

## Table of Contents

1. [Current Implementation Analysis](#current-implementation-analysis)
2. [PINCache Internals](#pincache-internals)
3. [Why Sync Works for Small Files but Not Large Videos](#why-sync-works-for-small-files-but-not-large-videos)
4. [Production Best Practices](#production-best-practices)
5. [Recommended Architecture](#recommended-architecture)
6. [Migration Path](#migration-path)
7. [Code Examples](#code-examples)
8. [References](#references)

---

## Current Implementation Analysis

### Sync Calls in Current Codebase

The current implementation uses **synchronous** cache operations:

```swift
// CachedAssetRepository.swift (formerly PINCacheAssetDataManager)
func retrieveAssetData() -> AssetData? {
    // SYNC call - blocks thread until disk I/O completes
    guard let assetData = cache.object(forKey: cacheKey) as? AssetData else {
        return nil
    }
    return assetData
}

func retrieveDataInRange(offset: Int64, length: Int) -> Data? {
    // Multiple SYNC disk reads - accumulates blocking time
    for chunkOffset in assetData.chunkOffsets {
        let chunkKey = "\(cacheKey)_chunk_\(chunkOffset)"
        // Each chunk = 1 disk read = 1-50ms blocking
        guard let chunkData = cache.object(forKey: chunkKey) as? Data else { ... }
    }
}
```

### Where Sync Calls Happen

| Location | Call | Thread | Risk Level |
|----------|------|--------|------------|
| `ResourceLoader` | `retrieveAssetData()` | `loaderQueue` (background) | Low |
| `ResourceLoader` | `retrieveDataInRange()` | `loaderQueue` (background) | Medium |
| `VideoCacheService` | `getCachePercentage()` | Main (via timer) | **High** |
| `VideoCacheService` | `isCached()` | Main (via ViewModel) | **High** |

### Current Mitigation (VideoPlayerViewModel)

```swift
// CachedVideoPlayer.swift - Moved sync call off main thread
private let cacheQueryQueue = DispatchQueue(label: "com.videodemo.cacheQuery", qos: .userInitiated)

private func fetchIsCached(completion: @escaping (Bool) -> Void) {
    cacheQueryQueue.async { [weak self] in
        guard let self = self else { return }
        let cached = self.cacheQuery.isCached(url: self.url)
        DispatchQueue.main.async {
            completion(cached)
        }
    }
}
```

---

## PINCache Internals

### Two-Level Cache Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        PINCache                              │
│                                                              │
│   object(forKey: "video.mp4")                               │
│        │                                                     │
│        ▼                                                     │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  1. Check PINMemoryCache (FAST)                     │   │
│   │     - In-memory dictionary                          │   │
│   │     - Protected by dispatch_semaphore               │   │
│   │     - Microseconds access time                      │   │
│   │                                                     │   │
│   │     Found? → Return immediately                     │   │
│   └─────────────────────────────────────────────────────┘   │
│        │                                                     │
│        │ Not found in memory                                 │
│        ▼                                                     │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  2. Check PINDiskCache (SLOWER)                     │   │
│   │     - File system read                              │   │
│   │     - Protected by dispatch_semaphore               │   │
│   │     - Milliseconds access time                      │   │
│   │                                                     │   │
│   │     Found? → Load into memory → Return              │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Thread Safety Mechanism

PINCache uses `dispatch_semaphore` as locks:

```swift
// Simplified PINDiskCache internal logic
func object(forKey key: String) -> Any? {
    // Acquire lock (blocks if another thread is accessing)
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER)

    // Read from disk (BLOCKING I/O)
    let data = FileManager.default.contents(atPath: filePath)
    let object = NSKeyedUnarchiver.unarchiveObject(with: data)

    // Release lock
    dispatch_semaphore_signal(lock)

    return object
}
```

### Performance Characteristics

| Cache Layer | Access Time | Blocking |
|-------------|-------------|----------|
| Memory Cache | ~1-10 μs | Minimal |
| Disk Cache | ~1-50 ms | **Blocks calling thread** |

---

## Why Sync Works for Small Files but Not Large Videos

### Original ZPlayerCacher Author Warning

> "Because this is for caching music files around 10 MB in size, PINCache can be used as the local cache tool; if it were for videos, this method wouldn't work (loading several GBs of data into memory at once)."
>
> "For this requirement, you can refer to the expert's approach, using FileHandle's seek and read/write features for handling."

### Comparison Table

| Aspect | Music (~10MB) | Video (100MB-1GB+) |
|--------|---------------|-------------------|
| **Data in memory** | Fits in memory cache | Too large, evicted frequently |
| **Disk reads** | 1-2 reads | 100s of chunk reads |
| **Blocking time** | 10-50ms (acceptable) | 1-10 seconds (unacceptable) |
| **Memory pressure** | Low | High (can cause OOM) |
| **Chunk count** | ~20 chunks | 200+ chunks |

### The Math Problem

For a 100MB video with 512KB chunks:
- Chunks: 100MB / 512KB = **200 chunks**
- Disk read per chunk: ~10ms
- Total blocking time: 200 × 10ms = **2 seconds!**

This would freeze the UI if called on main thread.

---

## Production Best Practices

### 1. Use FileHandle for Large Files

```swift
class FileHandleAssetDataManager {
    private let fileHandle: FileHandle
    private let metadataURL: URL

    func readData(offset: Int64, length: Int) throws -> Data {
        try fileHandle.seek(toOffset: UInt64(offset))
        return fileHandle.readData(ofLength: length)
    }

    func writeData(_ data: Data, at offset: Int64) throws {
        try fileHandle.seek(toOffset: UInt64(offset))
        fileHandle.write(data)
    }
}
```

**Benefits:**
- No memory bloat (streams directly to/from disk)
- Seek to any offset without loading entire file
- Efficient for range-based access

### 2. Use Swift Actors for Thread Safety

```swift
actor VideoAssetRepository {
    private let fileHandle: FileHandle
    private var metadata: AssetMetadata?

    func retrieveData(offset: Int64, length: Int) async throws -> Data {
        // Actor ensures exclusive access
        try fileHandle.seek(toOffset: UInt64(offset))
        return fileHandle.readData(ofLength: length)
    }

    func saveData(_ data: Data, at offset: Int64) async throws {
        try fileHandle.seek(toOffset: UInt64(offset))
        fileHandle.write(data)
        updateCachedRanges(offset: offset, length: data.count)
    }
}
```

**Benefits:**
- Compiler-enforced thread safety
- No manual locks needed
- Clear async/await syntax

### 3. Handle Actor Reentrancy

```swift
actor CacheActor {
    private var cache: [String: Task<Data?, Never>] = [:]

    func getData(for key: String) async -> Data? {
        // Check if already fetching (prevent duplicate work)
        if let existingTask = cache[key] {
            return await existingTask.value
        }

        // Create new task and cache it BEFORE await
        let task = Task {
            await fetchFromDisk(key)
        }
        cache[key] = task  // Set before suspension!

        return await task.value
    }
}
```

### 4. Wrap FileHandle in Background Queue

FileHandle operations are blocking I/O that can violate Swift's cooperative threading model:

```swift
func readDataAsync(offset: Int64, length: Int) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            self.fileHandle.seek(toFileOffset: UInt64(offset))
            let data = self.fileHandle.readData(ofLength: length)
            continuation.resume(returning: data)
        }
    }
}
```

---

## Recommended Architecture

### Production Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ ResourceLoader (AVAssetResourceLoaderDelegate)                               │
│                                                                              │
│   shouldWaitForLoadingOfRequestedResource:                                   │
│       1. Return true immediately (non-blocking)                              │
│       2. Spawn Task to handle async                                          │
│       3. Call finishLoading() when done                                      │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ VideoAssetRepository (Actor - Thread Safe)                                   │
│                                                                              │
│   func retrieveData(offset:length:) async -> Data?                          │
│   func saveData(_:at:) async                                                │
│   func isRangeCached(offset:length:) async -> Bool                          │
│                                                                              │
│   Internally:                                                                │
│   - Uses Task caching to prevent duplicate fetches                          │
│   - Manages reentrancy correctly                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│ FileHandleStorage (Background Queue)                                         │
│                                                                              │
│   - FileHandle for video data (seek + read/write)                           │
│   - Separate metadata file (JSON/Plist)                                     │
│   - No memory bloat (streams directly to/from disk)                         │
│   - Wrapped in DispatchQueue.global() for non-blocking                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Protocol Changes

```swift
// BEFORE (sync - blocks thread)
protocol AssetDataRepository {
    func retrieveAssetData() -> AssetData?
    func retrieveDataInRange(offset: Int64, length: Int) -> Data?
    func saveDownloadedData(_ data: Data, offset: Int)
}

// AFTER (async - non-blocking)
protocol AssetDataRepository {
    func retrieveAssetData() async -> AssetData?
    func retrieveDataInRange(offset: Int64, length: Int) async -> Data?
    func saveDownloadedData(_ data: Data, offset: Int) async
}
```

---

## Migration Path

### Phase 1: Keep PINCache for Metadata, Add Async Wrappers

```swift
// Wrap existing sync calls in background queue
extension CachedAssetRepository {
    func retrieveAssetDataAsync() async -> AssetData? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.retrieveAssetData()
                continuation.resume(returning: result)
            }
        }
    }
}
```

### Phase 2: Implement FileHandleAssetRepository

```swift
actor FileHandleAssetRepository: AssetDataRepository {
    private let videoFileURL: URL
    private let metadataFileURL: URL
    private var fileHandle: FileHandle?
    private var metadata: AssetMetadata?

    func retrieveData(offset: Int64, length: Int) async throws -> Data {
        guard let handle = fileHandle else {
            throw CacheError.fileNotFound
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    let data = handle.readData(ofLength: length)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
```

### Phase 3: Update ResourceLoader for Async

```swift
// ResourceLoader.swift
func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
) -> Bool {
    // Return true immediately (non-blocking)
    handleRequestAsync(loadingRequest)
    return true
}

private func handleRequestAsync(_ request: AVAssetResourceLoadingRequest) {
    Task {
        do {
            let data = try await repository.retrieveDataInRange(
                offset: offset,
                length: length
            )

            if let data = data, data.count == length {
                // Cache hit
                request.dataRequest?.respond(with: data)
                request.finishLoading()
            } else {
                // Cache miss - fetch from network
                await fetchFromNetwork(request)
            }
        } catch {
            request.finishLoading(with: error)
        }
    }
}
```

### Phase 4: Update UI Layer

```swift
// VideoCacheQuerying protocol with async
protocol VideoCacheQuerying: AnyObject {
    func getCachePercentage(for url: URL) async -> Double
    func isCached(url: URL) async -> Bool
    func getCacheSize() async -> Int64
    func clearCache() async
}

// ViewModel usage
private func checkCacheStatus() {
    Task {
        let cached = await cacheQuery.isCached(url: url)
        await MainActor.run {
            self.isCached = cached
            self.isDownloading = !cached
        }
    }
}
```

---

## Code Examples

### Current (Demo) vs Production Comparison

| Aspect | Current (Demo) | Production |
|--------|----------------|------------|
| Storage | PINCache (memory + disk) | FileHandle (disk only) |
| API | Sync | Async |
| Thread Safety | dispatch_semaphore | Swift Actor |
| Metadata | In AssetData object | Separate JSON file |
| Memory Usage | Loads chunks into memory | Streams from disk |
| Max Video Size | ~100MB | Unlimited |

### VIMediaCache Reference

[VIMediaCache](https://github.com/vitoziv/VIMediaCache) is a production-ready implementation that uses:
- FileHandle for video data
- Separate metadata file
- Range-based caching
- AVAssetResourceLoaderDelegate

---

## Challenges & Solutions

### Challenge 1: AVAssetResourceLoaderDelegate is Sync-Based

The delegate method must return `Bool` synchronously, but cache operations should be async.

**Solution:**
```swift
func shouldWaitForLoadingOfRequestedResource(...) -> Bool {
    // Return true immediately
    handleRequestAsync(loadingRequest)  // Spawn Task
    return true  // Non-blocking
}
```

### Challenge 2: Actor Reentrancy

During `await`, other calls can access the actor, potentially causing duplicate work.

**Solution:** Cache the Task, not the result:
```swift
actor CacheActor {
    private var inFlightTasks: [String: Task<Data?, Never>] = [:]

    func getData(for key: String) async -> Data? {
        if let task = inFlightTasks[key] {
            return await task.value  // Wait for existing
        }

        let task = Task { await fetchFromDisk(key) }
        inFlightTasks[key] = task  // Cache BEFORE await

        defer { inFlightTasks[key] = nil }
        return await task.value
    }
}
```

### Challenge 3: FileHandle Blocking I/O

FileHandle operations block the thread, violating Swift's cooperative threading.

**Solution:** Use DispatchQueue or DispatchIO:
```swift
func readAsync() async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let data = fileHandle.readData(ofLength: length)
            continuation.resume(returning: data)
        }
    }
}
```

---

## Decision Matrix

### When to Use Each Approach

| Scenario | Recommended Approach |
|----------|---------------------|
| Demo/Prototype | Current PINCache (sync) |
| Small files (<50MB) | PINCache with async wrappers |
| Large files (>100MB) | FileHandle + Actor |
| Production app | FileHandle + Actor + Async |
| Maximum performance | DispatchIO + Actor |

### Current Project Status

- **Current:** PINCache sync (suitable for demo)
- **Mitigations:** Background queue for UI cache queries
- **Next step:** FileHandle implementation for production

---

## References

### Articles
- [How to Cache AVURLAsset - Medium](https://medium.com/@vdugnist/how-to-cache-avurlasset-data-downloaded-by-avplayer-5400677b8b9e)
- [Swift Actors for Thread Safety](https://swiftwithmajid.com/2023/09/19/thread-safety-in-swift-with-actors/)
- [Mastering Async Operations and Thread-Safe Caching](https://medium.com/@shubhamsanghavi100/mastering-async-operations-and-thread-safe-caching-in-scalable-ios-apps-543b403a3e8f)

### Swift Forums
- [Structured Caching in Actor](https://forums.swift.org/t/structured-caching-in-an-actor/65501)
- [Task-safe File Writing](https://forums.swift.org/t/task-safe-way-to-write-a-file-asynchronously/54639)

### Libraries
- [VIMediaCache](https://github.com/vitoziv/VIMediaCache) - FileHandle-based video cache
- [KTVHTTPCache](https://github.com/ChangbaDevs/KTVHTTPCache) - HTTP proxy cache
- [PINCache](https://github.com/pinterest/PINCache) - Memory + disk cache

### Apple Documentation
- [AVAssetResourceLoaderDelegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate)
- [Swift Concurrency - WWDC21](https://developer.apple.com/videos/play/wwdc2021/10254/)

---

**Document Status:** Complete
**Last Updated:** January 2026
**Next Action:** Implement FileHandle-based repository when scaling to production
