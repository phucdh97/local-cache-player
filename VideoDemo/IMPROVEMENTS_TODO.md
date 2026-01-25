# Improvements TODO

This document outlines critical improvements needed for production readiness.
Priority: 🔴 Critical | 🟡 Important | 🟢 Nice-to-have

---

## 🔴 CRITICAL #1: Fix Actor Isolation Issues (Swift 6 Compatibility)

### Problem
Several methods in `VideoCacheManager.swift` have concurrency issues:
1. `isCached()` is actor-isolated but called without `await`
2. Mixing isolated and non-isolated method calls
3. Will break in Swift 6 strict concurrency mode

### Current Code (BROKEN)
```swift
// VideoCacheManager.swift:282-287
func isCached(url: URL) -> Bool {
    if let metadata = metadataCache[cacheKey(for: url)], metadata.isFullyCached {
        return true
    }
    return false
}

// CachedVideoPlayerManager.swift:37
if cacheManager.isCached(url: url) {  // ❌ Missing await
    print("🎬 Created player item for cached video...")
}
```

### Solution: Make Synchronous Non-Isolated Method

**File: VideoCacheManager.swift**

Replace lines 282-287 with:
```swift
/// Check if video is fully cached (synchronous, thread-safe)
/// Non-isolated: Safe because it only reads from disk
nonisolated func isCached(url: URL) -> Bool {
    // Check disk-based metadata file directly
    let metadataPath = metadataFilePath(for: url)
    guard FileManager.default.fileExists(atPath: metadataPath.path) else {
        return false
    }

    do {
        let data = try Data(contentsOf: metadataPath)
        let metadata = try JSONDecoder().decode(CacheMetadata.self, from: data)
        return metadata.isFullyCached
    } catch {
        return false
    }
}
```

**Benefits:**
- ✅ Can be called synchronously (no `await` needed)
- ✅ Thread-safe (reads from disk, no shared state)
- ✅ Swift 6 compatible
- ✅ Works in synchronous contexts

---

## 🔴 CRITICAL #2: Dictionary-Based Request Tracking

### Problem
Current implementation uses an array to track loading requests, which doesn't map individual requests to their network operations. This can cause issues with:
- Multiple concurrent range requests
- Rapid seeking
- Request cancellation

### Current Code (LESS ROBUST)
```swift
// VideoResourceLoaderDelegate.swift:14
private var loadingRequests: [AVAssetResourceLoadingRequest] = []
private var downloadTask: URLSessionDataTask?  // Only ONE task for ALL requests
```

### Solution: Extract ResourceLoaderRequest Class

**File: VideoResourceLoaderRequest.swift** (NEW FILE)

```swift
//
//  VideoResourceLoaderRequest.swift
//  VideoDemo
//
//  Handles individual resource loading requests with dedicated network tasks
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import AVFoundation

/// Manages a single AVAssetResourceLoadingRequest with its own URLSession task
class VideoResourceLoaderRequest: NSObject {

    // MARK: - Properties

    private let originalURL: URL
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let cacheManager = VideoCacheManager.shared

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var response: HTTPURLResponse?

    private var downloadOffset: Int64 = 0
    private var expectedContentLength: Int64 = 0

    // Thread-safe chunk storage
    private let chunksQueue = DispatchQueue(label: "com.videocache.request.chunks")
    private var receivedChunks: [(offset: Int64, data: Data)] = []

    private var isCancelled = false

    // MARK: - Initialization

    init(originalURL: URL, loadingRequest: AVAssetResourceLoadingRequest) {
        self.originalURL = originalURL
        self.loadingRequest = loadingRequest
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public Methods

    func start() {
        guard !isCancelled else { return }

        // Try to fulfill from cache first
        Task {
            if await tryFulfillFromCache() {
                return
            }

            // Start network request
            startNetworkRequest()
        }
    }

    func cancel() {
        isCancelled = true
        dataTask?.cancel()
        session?.invalidateAndCancel()

        chunksQueue.async { [weak self] in
            self?.receivedChunks.removeAll()
        }

        print("❌ Request cancelled for offset: \(loadingRequest.dataRequest?.requestedOffset ?? 0)")
    }

    // MARK: - Private Methods

    private func tryFulfillFromCache() async -> Bool {
        // Fill content information if requested
        if let infoRequest = loadingRequest.contentInformationRequest {
            await fillInfoRequest(infoRequest)
        }

        // Try to fill data request from cache
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let offset = dataRequest.currentOffset
        let length = dataRequest.requestedLength - Int(offset - dataRequest.requestedOffset)

        // Check if range is cached
        if await cacheManager.isRangeCached(for: originalURL, offset: offset, length: Int64(length)) {
            if let cachedData = cacheManager.cachedData(for: originalURL, offset: offset, length: length) {
                dataRequest.respond(with: cachedData)
                loadingRequest.finishLoading()
                print("✅ Fulfilled from cache: offset=\(offset), length=\(cachedData.count)")
                return true
            }
        }

        return false
    }

    private func fillInfoRequest(_ infoRequest: AVAssetResourceLoadingContentInformationRequest) async {
        if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
           let contentLength = metadata.contentLength {
            infoRequest.contentLength = contentLength
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentType = metadata.contentType ?? "video/mp4"
            return
        }

        // Will be filled when response is received
    }

    private func startNetworkRequest() {
        guard !isCancelled else { return }

        let dataRequest = loadingRequest.dataRequest
        let offset = dataRequest?.requestedOffset ?? 0

        // Check for partial cache to resume from
        let cachedSize = cacheManager.getCachedDataSize(for: originalURL)
        downloadOffset = max(offset, cachedSize)

        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Set Range header
        if downloadOffset > 0 {
            request.setValue("bytes=\(downloadOffset)-", forHTTPHeaderField: "Range")
            print("📍 Starting request from offset: \(downloadOffset)")
        }

        dataTask = session?.dataTask(with: request)
        dataTask?.resume()
    }

    private func processLoadingRequest() {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let requestedOffset = dataRequest.requestedOffset
        let currentOffset = dataRequest.currentOffset
        let requestedLength = dataRequest.requestedLength
        let availableLength = requestedLength - Int(currentOffset - requestedOffset)

        // Try to serve from received chunks
        chunksQueue.sync {
            for chunk in receivedChunks {
                let chunkEnd = chunk.offset + Int64(chunk.data.count)

                if currentOffset >= chunk.offset && currentOffset < chunkEnd {
                    let chunkOffset = Int(currentOffset - chunk.offset)
                    let availableInChunk = min(availableLength, chunk.data.count - chunkOffset)

                    if chunkOffset >= 0 && chunkOffset < chunk.data.count {
                        let data = chunk.data.subdata(in: chunkOffset..<(chunkOffset + availableInChunk))
                        dataRequest.respond(with: data)
                        print("✅ Responded with chunk: \(data.count) bytes")

                        // Check if request is complete
                        if dataRequest.currentOffset >= requestedOffset + Int64(requestedLength) {
                            loadingRequest.finishLoading()
                            print("✅ Request completed")
                        }

                        return
                    }
                }
            }
        }
    }

    deinit {
        cancel()
        print("♻️ VideoResourceLoaderRequest deinitialized")
    }
}

// MARK: - URLSessionDataDelegate

extension VideoResourceLoaderRequest: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive response: URLResponse,
                   completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        self.response = response as? HTTPURLResponse

        if let httpResponse = response as? HTTPURLResponse {
            // Fill content information if needed
            if let infoRequest = loadingRequest.contentInformationRequest {
                let contentLength = httpResponse.statusCode == 206 ?
                    parseContentRangeTotal(httpResponse) : httpResponse.expectedContentLength

                expectedContentLength = contentLength
                infoRequest.contentLength = contentLength
                infoRequest.isByteRangeAccessSupported = true
                infoRequest.contentType = httpResponse.mimeType ?? "video/mp4"

                // Save metadata
                Task {
                    await cacheManager.saveCacheMetadata(
                        for: originalURL,
                        contentLength: contentLength,
                        contentType: infoRequest.contentType
                    )
                }
            }
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive data: Data) {

        guard !isCancelled else { return }

        let currentPosition = downloadOffset
        downloadOffset += Int64(data.count)

        // Store in chunks
        chunksQueue.async { [weak self] in
            guard let self = self else { return }
            self.receivedChunks.append((offset: currentPosition, data: data))

            // Keep only recent chunks (prevent memory growth)
            if self.receivedChunks.count > 20 {
                self.receivedChunks.removeFirst()
            }
        }

        // Cache to disk
        cacheManager.cacheChunk(data, for: originalURL, at: currentPosition)

        // Update cached ranges
        Task {
            await cacheManager.addCachedRange(for: originalURL, offset: currentPosition, length: Int64(data.count))
        }

        // Try to fulfill loading request
        DispatchQueue.main.async { [weak self] in
            self?.processLoadingRequest()
        }

        print("💾 Received chunk: \(data.count) bytes at \(currentPosition)")
    }

    func urlSession(_ session: URLSession,
                   task: URLSessionTask,
                   didCompleteWithError error: Error?) {

        if let error = error {
            print("❌ Request error: \(error.localizedDescription)")
            loadingRequest.finishLoading(with: error)
        } else {
            print("✅ Download complete: \(downloadOffset) bytes")

            Task {
                await cacheManager.markAsFullyCached(for: originalURL, size: downloadOffset)
            }

            // Try final fulfillment
            processLoadingRequest()
        }

        // Cleanup
        chunksQueue.async { [weak self] in
            self?.receivedChunks.removeAll()
        }
    }

    private func parseContentRangeTotal(_ response: HTTPURLResponse) -> Int64 {
        if let contentRange = response.allHeaderFields["Content-Range"] as? String,
           let totalSizeStr = contentRange.split(separator: "/").last {
            return Int64(totalSizeStr) ?? response.expectedContentLength
        }
        return response.expectedContentLength
    }
}
```

**File: VideoResourceLoaderDelegate.swift** (REFACTORED)

Replace the current implementation with:

```swift
//
//  VideoResourceLoaderDelegate.swift
//  VideoDemo
//
//  Handles AVAssetResourceLoader requests using dictionary-based request tracking
//

import Foundation
import AVFoundation

class VideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {

    private let originalURL: URL

    // 🎯 KEY IMPROVEMENT: Dictionary tracks each request independently
    private var requests: [AVAssetResourceLoadingRequest: VideoResourceLoaderRequest] = [:]
    private let requestsQueue = DispatchQueue(label: "com.videocache.requests")

    init(url: URL) {
        self.originalURL = url
        super.init()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {

        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        let length = loadingRequest.dataRequest?.requestedLength ?? 0
        print("📥 New loading request: offset=\(offset), length=\(length)")

        requestsQueue.async { [weak self] in
            guard let self = self else { return }

            // Create dedicated request handler
            let request = VideoResourceLoaderRequest(originalURL: self.originalURL, loadingRequest: loadingRequest)

            // Cancel any existing request for same loading request
            self.requests[loadingRequest]?.cancel()

            // Store and start
            self.requests[loadingRequest] = request
            request.start()
        }

        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {

        print("❌ Loading request cancelled")

        requestsQueue.async { [weak self] in
            guard let self = self else { return }

            self.requests[loadingRequest]?.cancel()
            self.requests.removeValue(forKey: loadingRequest)
        }
    }

    // MARK: - Download Control

    func stopDownload() {
        requestsQueue.async { [weak self] in
            guard let self = self else { return }

            // Cancel all active requests
            for (_, request) in self.requests {
                request.cancel()
            }

            self.requests.removeAll()
            print("🛑 All requests stopped")
        }
    }

    deinit {
        stopDownload()
        print("♻️ VideoResourceLoaderDelegate deinitialized")
    }
}
```

**Benefits:**
- ✅ Each request has dedicated URLSession task
- ✅ Handles multiple concurrent range requests
- ✅ Better cancellation management
- ✅ Matches reference implementation pattern
- ✅ More robust for complex seeking scenarios

---

## 🔴 CRITICAL #3: Add Cache Size Management (LRU Eviction)

### Problem
Current implementation has no cache size limit. Videos accumulate indefinitely, eventually filling device storage.

### Solution: Implement LRU Cache Management

**File: VideoCacheManager.swift**

Add these methods after line 248 (after `markAsFullyCached()`):

```swift
// MARK: - Cache Size Management

/// Maximum cache size in bytes (default: 500MB)
private var maxCacheSize: Int64 = 500 * 1024 * 1024

/// Set maximum cache size
func setMaxCacheSize(_ bytes: Int64) {
    maxCacheSize = bytes
    print("📊 Max cache size set to: \(formatBytes(bytes))")
}

/// Enforce cache size limit using LRU eviction
func enforceCacheSizeLimit() async {
    let currentSize = getCacheSize()

    guard currentSize > maxCacheSize else {
        print("✅ Cache size OK: \(formatBytes(currentSize)) / \(formatBytes(maxCacheSize))")
        return
    }

    print("⚠️ Cache size exceeded: \(formatBytes(currentSize)) / \(formatBytes(maxCacheSize))")
    print("🗑️ Starting LRU eviction...")

    // Get all cached videos sorted by last access time (LRU)
    var cacheEntries: [(url: String, metadata: CacheMetadata, size: Int64)] = []

    for (key, metadata) in metadataCache {
        // Reconstruct URL from key (reverse of cacheKey method)
        if let urlString = key.removingPercentEncoding,
           let url = URL(string: urlString) {
            let size = getCachedFileSize(for: url) ?? 0
            cacheEntries.append((url: urlString, metadata: metadata, size: size))
        }
    }

    // Sort by lastModified (oldest first = least recently used)
    cacheEntries.sort { $0.metadata.lastModified < $1.metadata.lastModified }

    // Remove oldest entries until under limit
    var freedSpace: Int64 = 0
    var removedCount = 0

    for entry in cacheEntries {
        guard currentSize - freedSpace > maxCacheSize else { break }

        if let url = URL(string: entry.url) {
            await removeCache(for: url)
            freedSpace += entry.size
            removedCount += 1
            print("  🗑️ Removed: \(url.lastPathComponent) (\(formatBytes(entry.size)))")
        }
    }

    let newSize = getCacheSize()
    print("✅ Evicted \(removedCount) videos, freed \(formatBytes(freedSpace))")
    print("📊 New cache size: \(formatBytes(newSize)) / \(formatBytes(maxCacheSize))")
}

/// Remove cached video and metadata
func removeCache(for url: URL) async {
    let key = cacheKey(for: url)

    // Remove from in-memory cache
    metadataCache.removeValue(forKey: key)

    // Remove files
    let filePath = cacheFilePath(for: url)
    let metadataPath = metadataFilePath(for: url)

    let fileManager = FileManager.default

    try? fileManager.removeItem(at: filePath)
    try? fileManager.removeItem(at: metadataPath)

    print("🗑️ Removed cache for: \(url.lastPathComponent)")
}

/// Update last access time (call when video is played)
func touchCache(for url: URL) async {
    let key = cacheKey(for: url)

    guard var metadata = metadataCache[key] else { return }

    metadata.lastModified = Date()
    metadataCache[key] = metadata

    // Save to disk
    Task.detached { [metadata, metadataPath = metadataFilePath(for: url)] in
        do {
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: metadataPath)
        } catch {
            print("❌ Error updating metadata timestamp: \(error)")
        }
    }
}

/// Format bytes for human-readable output
private func formatBytes(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1024.0 / 1024.0
    if mb >= 1024 {
        return String(format: "%.2f GB", mb / 1024.0)
    } else {
        return String(format: "%.2f MB", mb)
    }
}
```

**Usage: Call after each successful cache write**

In `VideoResourceLoaderRequest.swift`, after caching completes:

```swift
func urlSession(_ session: URLSession,
               task: URLSessionTask,
               didCompleteWithError error: Error?) {

    if error == nil {
        Task {
            await cacheManager.markAsFullyCached(for: originalURL, size: downloadOffset)

            // 🎯 Enforce cache size limit
            await cacheManager.enforceCacheSizeLimit()
        }
    }
}
```

**Also update `CachedVideoPlayerManager.swift`:**

```swift
func createPlayerItem(with url: URL) -> AVPlayerItem {
    // ... existing code ...

    // Touch cache to update LRU timestamp
    Task {
        await cacheManager.touchCache(for: url)
    }

    return AVPlayerItem(asset: asset)
}
```

**Benefits:**
- ✅ Prevents unlimited cache growth
- ✅ Automatically removes least recently used videos
- ✅ Configurable cache size limit
- ✅ Production-ready storage management

---

## 🟡 IMPORTANT #4: Fix Potential URLSession Memory Leak

### Problem
URLSession created with `delegate: self` creates a strong reference cycle. If `deinit` doesn't get called, the session leaks.

### Solution: Use Weak Delegate Pattern

**File: VideoResourceLoaderRequest.swift**

Replace the initialization with:

```swift
private weak var weakSelf: VideoResourceLoaderRequest?

init(originalURL: URL, loadingRequest: AVAssetResourceLoadingRequest) {
    self.originalURL = originalURL
    self.loadingRequest = loadingRequest
    super.init()

    self.weakSelf = self  // Store weak reference

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    config.requestCachePolicy = .reloadIgnoringLocalCacheData

    // Use a delegateQueue to ensure delegate methods are called
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    self.session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
}
```

**Better Solution: Use closures instead of delegate for simple cases**

Actually, your current approach is fine because you call `invalidateAndCancel()` in `deinit`. Just ensure the `deinit` is always called by avoiding other retain cycles.

---

## 🟡 IMPORTANT #5: Add Comprehensive Error Handling

### Problem
Some error cases aren't handled gracefully:
- Corrupted cache files
- Disk full errors
- Invalid HTTP responses

### Solution: Add Error Recovery

**File: VideoCacheManager.swift**

Add validation method:

```swift
/// Validate cached file integrity
nonisolated func validateCache(for url: URL) -> Bool {
    let filePath = cacheFilePath(for: url)
    let metadataPath = metadataFilePath(for: url)

    guard FileManager.default.fileExists(atPath: filePath.path),
          FileManager.default.fileExists(atPath: metadataPath.path) else {
        return false
    }

    // Check if metadata is readable
    guard let metadata = try? Data(contentsOf: metadataPath),
          let decoded = try? JSONDecoder().decode(CacheMetadata.self, from: metadata) else {
        print("⚠️ Corrupted metadata, removing cache")
        try? FileManager.default.removeItem(at: filePath)
        try? FileManager.default.removeItem(at: metadataPath)
        return false
    }

    // Validate file size matches metadata
    if let contentLength = decoded.contentLength, decoded.isFullyCached {
        let actualSize = getCachedDataSize(for: url)
        if actualSize != contentLength {
            print("⚠️ Size mismatch: expected \(contentLength), got \(actualSize)")
            // Don't remove automatically - might be partial cache
        }
    }

    return true
}
```

**Call validation before serving cached data:**

```swift
private func tryFulfillFromCache() async -> Bool {
    // Validate cache integrity first
    if !cacheManager.validateCache(for: originalURL) {
        print("⚠️ Cache validation failed, re-downloading")
        return false
    }

    // ... existing cache fulfillment code ...
}
```

---

## 🟢 NICE-TO-HAVE #6: Add Progress Tracking

### Enhancement
Currently progress is logged but not exposed to UI.

### Solution: Add Progress Callback

**File: VideoResourceLoaderRequest.swift**

Add callback property:

```swift
var progressCallback: ((Double) -> Void)?

func urlSession(_ session: URLSession,
               dataTask: URLSessionDataTask,
               didReceive data: Data) {

    // ... existing code ...

    // Report progress
    if expectedContentLength > 0 {
        let progress = Double(downloadOffset) / Double(expectedContentLength)
        progressCallback?(progress)
    }
}
```

**Usage in UI:**

```swift
class VideoPlayerViewModel: ObservableObject {
    @Published var downloadProgress: Double = 0.0

    // Set callback when creating request
    request.progressCallback = { [weak self] progress in
        DispatchQueue.main.async {
            self?.downloadProgress = progress
        }
    }
}
```

---

## 🟢 NICE-TO-HAVE #7: Add Unit Tests

### Create Test File

**File: VideoCacheManagerTests.swift** (NEW)

```swift
import XCTest
@testable import VideoDemo

final class VideoCacheManagerTests: XCTestCase {

    var cacheManager: VideoCacheManager!
    var testURL: URL!

    override func setUp() async throws {
        cacheManager = VideoCacheManager.shared
        testURL = URL(string: "https://example.com/test.mp4")!
        await cacheManager.clearCache()
    }

    override func tearDown() async throws {
        await cacheManager.clearCache()
    }

    func testCacheKey() {
        let key = cacheManager.cacheKey(for: testURL)
        XCTAssertFalse(key.isEmpty)
        print("Cache key: \(key)")
    }

    func testCacheChunk() async throws {
        let testData = Data("Hello World".utf8)

        cacheManager.cacheChunk(testData, for: testURL, at: 0)

        let retrieved = cacheManager.cachedData(for: testURL, offset: 0, length: testData.count)
        XCTAssertEqual(retrieved, testData)
    }

    func testLRUEviction() async throws {
        // Set small cache size
        await cacheManager.setMaxCacheSize(1024 * 1024) // 1MB

        // Cache multiple videos
        let url1 = URL(string: "https://example.com/video1.mp4")!
        let url2 = URL(string: "https://example.com/video2.mp4")!

        let data = Data(count: 600 * 1024) // 600KB each

        cacheManager.cacheChunk(data, for: url1, at: 0)
        await cacheManager.markAsFullyCached(for: url1, size: Int64(data.count))

        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s

        cacheManager.cacheChunk(data, for: url2, at: 0)
        await cacheManager.markAsFullyCached(for: url2, size: Int64(data.count))

        // Should exceed limit, trigger eviction
        await cacheManager.enforceCacheSizeLimit()

        // url1 (older) should be evicted
        XCTAssertFalse(await cacheManager.isCached(url: url1))
        XCTAssertTrue(await cacheManager.isCached(url: url2))
    }
}
```

---

## Testing Checklist

After implementing improvements, verify:

- [ ] ✅ No compiler warnings in Swift 6 mode
- [ ] ✅ Can play multiple videos simultaneously without crashes
- [ ] ✅ Cache size stays under limit (test with small limit)
- [ ] ✅ LRU eviction removes oldest videos first
- [ ] ✅ Corrupted cache files are detected and removed
- [ ] ✅ Rapid seeking works smoothly
- [ ] ✅ App restart shows correct cache state
- [ ] ✅ Memory usage stays reasonable (<200MB)
- [ ] ✅ No URLSession leaks (check with Instruments)
- [ ] ✅ Progress callbacks work correctly

---

## Implementation Order

**Week 1: Critical Issues**
1. ✅ Fix actor isolation (CRITICAL #1) - 2 hours
2. ✅ Add cache size management (CRITICAL #3) - 3 hours
3. ✅ Test and validate - 2 hours

**Week 2: Important Refactoring**
4. ✅ Dictionary-based request tracking (CRITICAL #2) - 4-6 hours
5. ✅ Add error handling (IMPORTANT #5) - 2 hours
6. ✅ Test edge cases - 2 hours

**Week 3: Polish**
7. ✅ Add progress tracking (NICE-TO-HAVE #6) - 1 hour
8. ✅ Write unit tests (NICE-TO-HAVE #7) - 3 hours
9. ✅ Final testing and documentation - 2 hours

---

## Final Notes

Your implementation is already **very good** - these improvements will make it **production-ready**. The most critical ones are:

1. **Actor isolation fixes** (prevents Swift 6 issues)
2. **Cache size management** (prevents storage issues)
3. **Dictionary-based request tracking** (handles complex scenarios)

After these improvements, your implementation will be **better than most open-source solutions** because:
- ✅ Modern Swift concurrency (Actor pattern)
- ✅ Proper cache management (LRU eviction)
- ✅ Robust request handling (dictionary-based)
- ✅ Excellent documentation (your ISSUES_AND_SOLUTIONS.md is gold!)

Good luck! 🚀
