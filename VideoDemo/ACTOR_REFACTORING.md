# Actor-Based Thread Safety Refactoring

## Overview

This document describes the refactoring of `VideoCacheManager` from manual `NSLock` synchronization to Swift's modern `Actor` pattern for thread-safe video caching, including Swift 6 compliance updates.

## Updates

- **v1.0:** Initial Actor refactoring (NSLock → Actor for metadata)
- **v1.1:** Swift 6 compliance (FileManager local instances)
- **v1.2:** Removed unused `memoryCache` (already have `recentChunks` in ResourceLoader)
- **v1.3:** Refactored `recentChunks` from NSLock → Serial DispatchQueue (following blog's pattern)

---

## Why Actor Pattern?

### Problem with Original Implementation

```swift
// ❌ OLD: Manual NSLock - Error-prone
class VideoCacheManager {
    private var metadataCache: [String: CacheMetadata] = [:]
    private let metadataCacheLock = NSLock()  // Manual lock
    
    func getCacheMetadata(for url: URL) -> CacheMetadata? {
        metadataCacheLock.lock()  // Easy to forget!
        let cached = metadataCache[key]
        metadataCacheLock.unlock()  // Easy to forget!
        return cached
    }
}
```

**Issues:**
- ❌ Must manually lock/unlock everywhere
- ❌ Easy to forget locks (race conditions)
- ❌ Easy to forget unlocks (deadlocks)
- ❌ Verbose, repetitive code
- ❌ No compiler enforcement

**Real Bug We Hit (Issue #3):**
```
NSInvalidArgumentException: -[NSIndirectTaggedPointerString count]: 
unrecognized selector sent to instance
```
This happened when switching videos rapidly - dictionary corruption from concurrent access.

---

### Solution with Actor

```swift
// ✅ NEW: Actor - Compiler-enforced thread safety
actor VideoCacheManager {
    private var metadataCache: [String: CacheMetadata] = [:]
    
    func getCacheMetadata(for url: URL) -> CacheMetadata? {
        // ✅ Actor automatically serializes access!
        // ✅ No manual locks needed!
        // ✅ Compiler enforced!
        return metadataCache[key]
    }
}
```

**Benefits:**
- ✅ Automatic thread safety
- ✅ Compiler-enforced (can't forget)
- ✅ Clean, simple code
- ✅ No deadlocks possible
- ✅ Modern Swift (iOS 15+)

---

## Architecture: Actor + Non-Isolated Functions

### Key Design Decision

**Not everything needs to be actor-isolated!**

```
┌─────────────────────────────────────────┐
│      VideoCacheManager (Actor)          │
├─────────────────────────────────────────┤
│                                         │
│  Actor-Isolated (Metadata):            │
│  ✅ metadataCache dictionary            │
│  ✅ getCacheMetadata()                  │
│  ✅ saveCacheMetadata()                 │
│  ✅ addCachedRange()                    │
│  ✅ isRangeCached()                     │
│  ✅ markAsFullyCached()                 │
│  ✅ isCached()                          │
│  ✅ getCachePercentage()                │
│  ✅ clearCache()                        │
│                                         │
├─────────────────────────────────────────┤
│                                         │
│  Non-Isolated (File I/O):              │
│  🔓 cacheKey()                          │
│  🔓 cacheFilePath()                     │
│  🔓 getCachedDataSize()                 │
│  🔓 cachedData()                        │
│  🔓 cacheChunk()                        │
│  🔓 cacheData()                         │
│  🔓 getCachedFileSize()                 │
│  🔓 getCacheSize()                      │
│                                         │
└─────────────────────────────────────────┘
```

### Why Non-Isolated File Operations?

```swift
// FileHandle operations are inherently thread-safe
nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
    let filePath = cacheFilePath(for: url)
    
    // ✅ FileHandle.write() is thread-safe
    // ✅ No shared mutable state accessed
    // ✅ Can be called synchronously (better performance)
    let fileHandle = try FileHandle(forWritingTo: filePath)
    try fileHandle.seek(toOffset: UInt64(offset))
    fileHandle.write(data)
}
```

**Benefits:**
- ✅ No `await` needed (synchronous calls)
- ✅ Better performance (no actor queue overhead)
- ✅ Still thread-safe (FileHandle is thread-safe)
- ✅ Direct disk I/O

---

## Comparison: Before vs After

### Before (NSLock)

```swift
class VideoCacheManager {
    private var metadataCache: [String: CacheMetadata] = [:]
    private let metadataCacheLock = NSLock()
    
    func addCachedRange(for url: URL, offset: Int64, length: Int64) {
        let key = cacheKey(for: url)
        var metadata = getCacheMetadata(for: url) ?? CacheMetadata()
        
        let newRange = CachedRange(offset: offset, length: length)
        metadata.cachedRanges.append(newRange)
        metadata.cachedRanges = mergeOverlappingRanges(metadata.cachedRanges)
        metadata.lastModified = Date()
        
        // ❌ Manual locking
        metadataCacheLock.lock()
        metadataCache[key] = metadata
        metadataCacheLock.unlock()
        
        saveMetadataToDisk(metadata, for: url)
    }
}
```

**Usage:**
```swift
// Synchronous call
cacheManager.addCachedRange(for: url, offset: 0, length: 1000)
```

---

### After (Actor)

```swift
actor VideoCacheManager {
    private var metadataCache: [String: CacheMetadata] = [:]
    
    func addCachedRange(for url: URL, offset: Int64, length: Int64) {
        let key = cacheKey(for: url)
        var metadata = metadataCache[key] ?? CacheMetadata()
        
        let newRange = CachedRange(offset: offset, length: length)
        metadata.cachedRanges.append(newRange)
        metadata.cachedRanges = mergeOverlappingRanges(metadata.cachedRanges)
        metadata.lastModified = Date()
        
        // ✅ No manual locking - Actor handles it!
        metadataCache[key] = metadata
        
        // Save to disk asynchronously
        Task.detached { [metadata, url, path = metadataFilePath(for: url)] in
            let data = try? JSONEncoder().encode(metadata)
            try? data?.write(to: path)
        }
    }
}
```

**Usage:**
```swift
// ✅ Must use await (compiler enforced)
await cacheManager.addCachedRange(for: url, offset: 0, length: 1000)

// Or wrap in Task
Task {
    await cacheManager.addCachedRange(for: url, offset: 0, length: 1000)
}
```

---

## Integration with VideoResourceLoaderDelegate

### Challenge

`AVAssetResourceLoaderDelegate` methods are **synchronous**:

```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    // ❌ This is synchronous - can't await here!
    return true
}
```

But Actor methods require `await`:
```swift
let metadata = await cacheManager.getCacheMetadata(for: url)  // Needs await!
```

### Solution: Task Wrapper

```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    
    let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
    let length = loadingRequest.dataRequest?.requestedLength ?? 0
    
    // ✅ Wrap async operations in Task
    Task {
        if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
           await cacheManager.isRangeCached(for: originalURL, offset: offset, length: Int64(length)) {
            print("✅ Range is cached, serving from cache")
            await self.handleLoadingRequest(loadingRequest)
            return
        }
        
        self.loadingRequests.append(loadingRequest)
        await self.processLoadingRequests()
        
        if self.downloadTask == nil {
            self.startProgressiveDownload()
        }
    }
    
    return true  // Return immediately, processing continues in Task
}
```

**How it works:**
1. Return `true` immediately (don't block AVFoundation)
2. Start `Task` for async work
3. Process cache checks/updates asynchronously
4. Fulfill loading request when ready

---

## Performance Characteristics

### Actor-Isolated Operations (Serialized)

```swift
// These operations queue up (one at a time)
await cacheManager.getCacheMetadata(for: url1)      // ← Thread-safe
await cacheManager.addCachedRange(for: url2, ...)   // ← Waits for above
await cacheManager.markAsFullyCached(for: url3, ...) // ← Waits for above
```

**Impact:**
- ✅ Thread-safe (no race conditions)
- ⚠️ Serialized (one operation at a time)
- ✅ Fast for lightweight metadata operations (~1KB)

### Non-Isolated Operations (Parallel)

```swift
// These can run in parallel (no await needed)
cacheManager.cacheChunk(data1, for: url1, at: 0)     // ← Parallel
cacheManager.cacheChunk(data2, for: url2, at: 0)     // ← Parallel
cacheManager.cachedData(for: url3, offset: 0, ...)   // ← Parallel
```

**Impact:**
- ✅ Parallel execution (faster)
- ✅ No actor queue overhead
- ✅ Still thread-safe (FileHandle is thread-safe)

---

## Why Not Use PINCache?

### Blog Author's Warning

From [ZPlayerCacher blog](https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/):

> ⚠️ OOM Warning!
> 
> "Because this is for caching music files around 10 MB in size, PINCache can be used as the local cache tool; if it were for videos, this method wouldn't work (loading several GBs of data into memory at once)."

### PINCache Approach (Bad for Videos)

```swift
// ❌ PINCache stores entire video in memory
class AssetData: NSObject, NSCoding {
    var mediaData: Data = Data()  // 158 MB video = 158 MB RAM!
}

PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: key)
```

**Problems:**
- ❌ Entire video loaded into memory
- ❌ Multiple videos = OOM crash
- ❌ Can't handle HD/4K videos

### Our Approach (Good for Videos)

```swift
// ✅ We write directly to disk with FileHandle
nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
    let fileHandle = try FileHandle(forWritingTo: filePath)
    try fileHandle.seek(toOffset: UInt64(offset))
    fileHandle.write(data)  // Writes to disk, not memory!
}
```

**Benefits:**
- ✅ Only recent chunks in memory (~5 MB)
- ✅ Can handle videos of ANY size
- ✅ No OOM risk

---

## Thread Safety Guarantees

### What Actor Protects

```swift
actor VideoCacheManager {
    // ✅ Protected by Actor
    private var metadataCache: [String: CacheMetadata] = [:]
    
    func addCachedRange(...) {
        // ✅ Only one thread can modify metadataCache at a time
        metadataCache[key] = metadata
    }
}
```

**Guarantees:**
- ✅ No data races on `metadataCache`
- ✅ No dictionary corruption
- ✅ Fixes Issue #3 (NSIndirectTaggedPointerString crash)

### What's Still Thread-Safe Without Actor

```swift
// FileHandle is thread-safe for different file handles
nonisolated func cacheChunk(_ data: Data, for url: URL, at offset: Int64) {
    let fileHandle = try FileHandle(forWritingTo: filePath)
    fileHandle.write(data)  // ✅ Thread-safe
}
```

**Why safe:**
- Each call gets its own `FileHandle` instance
- OS handles concurrent file writes
- No shared mutable state

---

## Testing Thread Safety

### Before (Race Condition)

```swift
// Two videos downloading simultaneously:
Video 1: cacheManager.addCachedRange(...)  // Writing to dict
Video 2: cacheManager.getCacheMetadata(...) // Reading from dict
// ❌ CRASH: Dictionary corruption!
```

### After (Safe)

```swift
// Two videos downloading simultaneously:
Video 1: await cacheManager.addCachedRange(...)  // Queued
Video 2: await cacheManager.getCacheMetadata(...) // Waits for above
// ✅ SAFE: Actor serializes access
```

### Test Scenario

```swift
// Switch videos rapidly (stress test)
for url in videoURLs {
    Task {
        await cacheManager.saveCacheMetadata(for: url, ...)
        await cacheManager.addCachedRange(for: url, ...)
    }
}
// ✅ No crashes, no corruption
```

---

## Migration Checklist

If you want to verify the refactoring:

- [x] `VideoCacheManager` changed to `actor`
- [x] All NSLock instances removed
- [x] Metadata operations are actor-isolated
- [x] File operations are non-isolated
- [x] `CacheMetadata` and `CachedRange` marked as `Sendable`
- [x] VideoResourceLoaderDelegate uses `Task { await }` pattern
- [x] No linter errors
- [x] Builds successfully
- [x] All thread safety issues addressed

---

## Summary

| **Aspect** | **NSLock (Before)** | **Actor (After)** |
|------------|---------------------|-------------------|
| **Thread Safety** | ⚠️ Manual | ✅ Automatic |
| **Compiler Enforcement** | ❌ No | ✅ Yes |
| **Code Complexity** | ❌ High (lock/unlock pairs) | ✅ Low (clean) |
| **Error Prone** | ❌ High (easy to forget locks) | ✅ Low (can't forget) |
| **Deadlock Risk** | ⚠️ Possible | ✅ None |
| **Race Condition Risk** | ⚠️ Possible | ✅ None |
| **Performance (Metadata)** | ✅ Fast | ✅ Fast |
| **Performance (File I/O)** | ✅ Fast | ✅ Fast (non-isolated) |
| **iOS Version** | ✅ Any | ⚠️ iOS 15+ |

---

## Key Takeaways

1. **Actor is perfect for protecting shared mutable state**
   - Metadata dictionary → Actor-isolated ✅
   
2. **Not everything needs to be actor-isolated**
   - File I/O operations → Non-isolated ✅
   
3. **PINCache is unsuitable for large videos**
   - Our FileHandle approach supports any video size ✅
   
4. **Swift Actor prevents the bugs we actually hit**
   - Issue #3 (dictionary corruption) → Impossible with Actor ✅
   
5. **Modern Swift is safer and cleaner**
   - No manual locks, compiler-enforced correctness ✅

---

## Swift 6 Updates

### Issue: `nonisolated` with non-Sendable Types

Swift 6 introduced stricter concurrency checking. `FileManager` and `NSCache` are not marked as `Sendable`, causing errors:

```swift
// ❌ Swift 6 Error
nonisolated let fileManager = FileManager.default
// Error: 'nonisolated' can not be applied to variable with non-'Sendable' type
```

### Solution: Local Instances

Use local `FileManager.default` instances in each method:

```swift
// ✅ Swift 6 Compliant
nonisolated func cacheChunk(...) {
    let fileManager = FileManager.default  // Local instance
    // Use it...
}
```

**Why this works:**
- `FileManager.default` is a singleton (same object every time)
- Zero performance overhead
- Swift 6 compliant
- Each method is self-contained

### Removed: Unused `memoryCache`

The `NSCache<NSString, NSData>` was configured but never used. Removed because:
- ✅ Already have `recentChunks` in `VideoResourceLoaderDelegate`
- ✅ AVPlayer has its own buffer
- ✅ Simpler code, less memory usage

**Current caching layers:**
1. Metadata (small) → In-memory dictionary in `VideoCacheManager` (Actor-protected)
2. Recent chunks (~5MB) → Array in `VideoResourceLoaderDelegate` (Serial DispatchQueue-protected)
3. Full video → Disk with FileHandle

---

## RecentChunks: NSLock → Serial DispatchQueue

### Why Not Actor for RecentChunks?

While we used Actor for `VideoCacheManager.metadataCache`, `recentChunks` in `VideoResourceLoaderDelegate` uses a **Serial DispatchQueue** instead. Here's why:

**Challenge:**
- `VideoResourceLoaderDelegate` conforms to `AVAssetResourceLoaderDelegate` (Objective-C protocol)
- AVFoundation calls delegate methods **synchronously**
- Actors require `await` (async), but AVFoundation expects immediate return

**Solution: Serial DispatchQueue (Following Blog's Pattern)**

The blog's ZPlayerCacher uses a Serial DispatchQueue (`loaderQueue`) for all operations. We follow the same pattern:

```swift
// ✅ Before: NSLock (manual, error-prone)
class VideoResourceLoaderDelegate {
    private var recentChunks: [(offset: Int64, data: Data)] = []
    private let recentChunksLock = NSLock()
    
    func urlSession(...didReceive data: Data) {
        recentChunksLock.lock()  // Manual lock
        recentChunks.append(...)
        recentChunksLock.unlock()  // Easy to forget!
    }
}

// ✅ After: Serial DispatchQueue (automatic, safe)
class VideoResourceLoaderDelegate {
    private let recentChunksQueue = DispatchQueue(label: "com.videocache.recentchunks", qos: .userInitiated)
    private var recentChunks: [(offset: Int64, data: Data)] = []
    
    func urlSession(...didReceive data: Data) {
        recentChunksQueue.async { [weak self] in  // Automatic safety!
            self?.recentChunks.append(...)
        }
    }
    
    private func fillDataRequest(...) -> Bool {
        var foundData: Data? = nil
        recentChunksQueue.sync {  // Sync when immediate result needed
            // Search recentChunks...
            foundData = chunk.data.subdata(...)
        }
        return foundData != nil
    }
}
```

**Benefits:**
- ✅ No manual locks (can't forget unlock)
- ✅ No deadlocks (serial queue prevents them)
- ✅ Works with AVFoundation (sync access when needed)
- ✅ Matches blog's pattern (`loaderQueue`)
- ✅ Thread-safe by serialization

**Thread Safety Architecture:**

```
┌─────────────────────────────────────────┐
│  VideoCacheManager (Actor)             │
│  ✅ metadataCache → Actor-protected   │
│     (Modern Swift, async/await)        │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│  VideoResourceLoaderDelegate (Class)    │
│  ✅ recentChunks → Serial Queue        │
│     (Works with AVFoundation sync)      │
└─────────────────────────────────────────┘
```

**Why Serial DispatchQueue Instead of NSLock or Actor?**

We evaluated three options for `recentChunks` thread safety:

### Option 1: NSLock (Original - Rejected)

```swift
// ❌ NSLock approach
private let recentChunksLock = NSLock()

func urlSession(...didReceive data: Data) {
    recentChunksLock.lock()  // Manual lock
    recentChunks.append(...)
    recentChunksLock.unlock()  // Easy to forget!
}

private func fillDataRequest(...) -> Bool {
    recentChunksLock.lock()
    let data = recentChunks.find(...)  // Read
    recentChunksLock.unlock()
    return data
}
```

**Problems:**
- ❌ **Error-prone** - Easy to forget `unlock()` → deadlock
- ❌ **Easy to forget `lock()`** → race conditions
- ❌ **No compiler enforcement** - Runtime crashes
- ❌ **Verbose** - Lock/unlock pairs everywhere
- ❌ **Same bug we had** - Issue #3 (dictionary corruption)

**Why we rejected it:**
We already hit bugs with NSLock for `metadataCache`. Don't repeat the same mistake!

---

### Option 2: Actor (Considered - Rejected)

```swift
// ⚠️ Actor approach (doesn't work)
actor RecentChunksManager {
    private var chunks: [(offset: Int64, data: Data)] = []
    
    func addChunk(...) {
        chunks.append(...)
    }
    
    func findChunk(...) -> Data? {
        return chunks.find(...)
    }
}

// In VideoResourceLoaderDelegate:
class VideoResourceLoaderDelegate {
    private let chunksManager = RecentChunksManager()
    
    func urlSession(...didReceive data: Data) {
        Task {
            await chunksManager.addChunk(...)  // ✅ Works
        }
    }
    
    private func fillDataRequest(...) -> Bool {
        // ❌ PROBLEM: AVFoundation calls this synchronously!
        var foundData: Data? = nil
        Task {
            foundData = await chunksManager.findChunk(...)  // Async
        }
        // ❌ Can't wait for Task - AVFoundation needs immediate return!
        return foundData != nil  // Always nil!
    }
}
```

**Problems:**
- ❌ **AVFoundation is synchronous** - Delegate methods must return immediately
- ❌ **Can't use `await`** - Would block or require async methods (not allowed)
- ❌ **Task doesn't help** - Can't wait for result synchronously
- ❌ **Would need `Task.wait()`** - Blocks thread (bad!)

**Why we rejected it:**
AVFoundation's `AVAssetResourceLoaderDelegate` protocol requires **synchronous** methods. Actors require `await` (async), creating an impossible mismatch.

---

### Option 3: Serial DispatchQueue (Chosen ✅)

```swift
// ✅ Serial DispatchQueue approach
private let recentChunksQueue = DispatchQueue(label: "com.videocache.recentchunks")

func urlSession(...didReceive data: Data) {
    recentChunksQueue.async { [weak self] in  // Non-blocking write
        self?.recentChunks.append(...)
    }
}

private func fillDataRequest(...) -> Bool {
    var foundData: Data? = nil
    recentChunksQueue.sync {  // ✅ Synchronous read - works with AVFoundation!
        foundData = recentChunks.find(...)
    }
    return foundData != nil  // ✅ Immediate result!
}
```

**Benefits:**
- ✅ **No manual locks** - Queue handles synchronization automatically
- ✅ **Works with AVFoundation** - `sync` provides immediate result
- ✅ **No deadlocks** - Serial queue prevents them
- ✅ **Matches blog's pattern** - ZPlayerCacher uses `loaderQueue`
- ✅ **Simple code** - Just wrap operations in queue
- ✅ **Thread-safe** - Serialization ensures safety

**Why we chose it:**
Perfect balance: Automatic thread safety (like Actor) + Synchronous access (like NSLock) + Works with AVFoundation!

---

### Comparison Table

| Aspect | NSLock | Actor | Serial DispatchQueue |
|--------|--------|-------|----------------------|
| **Thread Safety** | ⚠️ Manual | ✅ Automatic | ✅ Automatic |
| **Synchronous Access** | ✅ Yes | ❌ No (requires await) | ✅ Yes (`sync`) |
| **Works with AVFoundation** | ✅ Yes | ❌ No | ✅ Yes |
| **Error-Prone** | ❌ High (forget locks) | ✅ Low | ✅ Low |
| **Deadlock Risk** | ⚠️ Possible | ✅ None | ✅ None |
| **Code Complexity** | ❌ High (lock/unlock) | ⚠️ Medium (Task wrapping) | ✅ Low (queue ops) |
| **Compiler Enforcement** | ❌ No | ✅ Yes | ⚠️ Partial |
| **Matches Blog Pattern** | ❌ No | ❌ No | ✅ Yes |

**Winner: Serial DispatchQueue** ✅

---

**Why Different Approaches?**

| Component | Thread Safety | Reason |
|-----------|---------------|--------|
| `metadataCache` | Actor | Can be async, modern Swift, no AVFoundation constraints |
| `recentChunks` | Serial Queue | Must work with sync AVFoundation, matches blog pattern |

Both are thread-safe, but use different patterns based on their constraints!

---

## References

- [Swift Concurrency Documentation](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [Swift Actors Proposal](https://github.com/apple/swift-evolution/blob/main/proposals/0306-actors.md)
- [Swift 6 Migration Guide](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/)
- [ZPlayerCacher Blog](https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/)
- [ISSUES_AND_SOLUTIONS.md](./ISSUES_AND_SOLUTIONS.md) - Our bug history

---

**Conclusion:** The Actor refactoring eliminates entire classes of concurrency bugs while making the code cleaner and more maintainable. Swift 6 compliance ensures future-proof code. The removal of unused components keeps the codebase lean and focused.


