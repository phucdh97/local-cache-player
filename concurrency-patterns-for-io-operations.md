# Swift Concurrency Patterns for I/O Operations

**Document Version:** 1.0  
**Last Updated:** 2025-12-28  
**Author:** iOS Engineering Team  
**Related:** video-player-improvement-proposal.md

---

## Table of Contents

- [Part 1: Understanding Concurrency Primitives](#part-1-understanding-concurrency-primitives)
  - [The Core Problem: Actor Re-entrancy](#the-core-problem-actor-re-entrancy)
  - [Actors](#actors)
  - [Serial Queues](#serial-queues)
  - [Locks](#locks)
  - [When to Combine Primitives](#when-to-combine-primitives)
  - [Decision Matrix](#decision-matrix)
- [Part 2: Application to Video Caching Problem](#part-2-application-to-video-caching-problem)
  - [The Problem](#the-problem)
  - [Why Order and Concurrency Matter](#why-order-and-concurrency-matter)
  - [Solution Architecture](#solution-architecture)
  - [Implementation Examples](#implementation-examples)
  - [Common Pitfalls](#common-pitfalls)

---

# Part 1: Understanding Concurrency Primitives

## The Core Problem: Actor Re-entrancy

**Critical Understanding:** Actors do NOT guarantee sequential execution due to suspension points.

```swift
actor Counter {
    var value = 0
    
    func increment() async {
        let current = value
        await Task.yield() // ⚠️ SUSPENSION POINT!
        value = current + 1  // ⚠️ Another task may have modified value!
    }
}

// Example of the problem:
let counter = Counter()

// These three calls are NOT guaranteed to execute in order:
Task { await counter.increment() }  // Might execute 2nd
Task { await counter.increment() }  // Might execute 1st  
Task { await counter.increment() }  // Might execute 3rd

// Final value might be 1, 2, or 3 (not guaranteed to be 3!)
```

**What happened:**
1. Three separate `Task` blocks are created
2. They race to call the actor
3. The actor serializes them, but in **arrival order** (non-deterministic)
4. Between `await` points, the actor can be re-entered by another task

---

## Actors

### What Actors Guarantee

✅ **Guaranteed:**
- **Mutual exclusion** - only one task executes at a time
- **Data race freedom** - no simultaneous access to mutable state
- **Thread safety** - safe to call from any thread

❌ **NOT Guaranteed:**
- **Execution order** - tasks may execute in any order
- **Sequential execution** - suspension points allow re-entrancy
- **FIFO ordering** - not first-in-first-out

### When to Use Actors

```swift
// ✅ GOOD: Actors for async I/O with proper structuring
actor FileCache {
    private var cache: [String: Data] = [:]
    
    func getData(for key: String) async throws -> Data {
        // Check cache first
        if let cached = cache[key] {
            return cached
        }
        
        // Download if not cached
        let data = try await downloadFromNetwork(key)
        
        // Cache for future use
        cache[key] = data
        
        return data
    }
}

// ✅ GOOD: Single task for ordered operations
Task {
    let data1 = await fileCache.getData(for: "file1")
    let data2 = await fileCache.getData(for: "file2")
    let data3 = await fileCache.getData(for: "file3")
}
// Guaranteed order: file1 → file2 → file3

// ❌ BAD: Multiple tasks (unordered)
Task { await fileCache.getData(for: "file1") }
Task { await fileCache.getData(for: "file2") }
Task { await fileCache.getData(for: "file3") }
// Order NOT guaranteed!
```

---

## Serial Queues

### What Serial Queues Guarantee

✅ **Guaranteed:**
- **FIFO execution** - tasks execute in submission order
- **Serial execution** - one task at a time
- **No suspension-based re-entrancy** - GCD doesn't have `await`

❌ **Limitations:**
- Not async/await friendly (requires bridging)
- Callback-based API (harder to reason about)
- Can't leverage structured concurrency

### When to Use Serial Queues

```swift
// ✅ GOOD: Legacy GCD code interop
class LegacyDownloader {
    private let downloadQueue = DispatchQueue(label: "downloads")
    
    func download(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        downloadQueue.async {
            // Legacy code that expects specific queue
            let data = self.legacyDownloadMethod(url)
            completion(.success(data))
        }
    }
}

// ✅ GOOD: Bridging to async/await
actor ModernDownloader {
    private let legacyQueue = DispatchQueue(label: "legacy")
    
    func download(url: URL) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            legacyQueue.async {
                // Legacy API that must run on specific queue
                do {
                    let data = try self.legacyAPI.download(url)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// ❌ BAD: Using queues for new async/await code
// Use actors instead!
```

---

## Locks

### What Locks Guarantee

✅ **Guaranteed:**
- **Mutual exclusion** for critical sections
- **No suspension points** - synchronous only
- **Fast** - minimal overhead for short critical sections

⚠️ **Critical Rules:**
- **NEVER hold lock across `await`** (causes deadlocks!)
- Only for synchronous operations
- Keep critical sections small

### When to Use Locks

```swift
// ✅ GOOD: Protecting synchronous file I/O
actor FileManager {
    private var files: [String: FileHandle] = [:]
    private let fileLock = NSLock()
    
    func writeData(_ data: Data, to file: String) async throws {
        let handle = try getFileHandle(for: file)
        
        // Lock for synchronous I/O (no await)
        fileLock.lock()
        defer { fileLock.unlock() }
        
        handle.seek(toFileOffset: 0)
        handle.write(data)
        handle.synchronizeFile()
        // No await = no re-entrancy possible
    }
}

// ❌ DEADLY: Holding lock across await (DEADLOCK!)
func badExample() async {
    lock.lock()
    await someAsyncWork()  // ⚠️ DEADLOCK! Lock held across suspension
    lock.unlock()
}

// ✅ GOOD: Lock only around sync operations
func goodExample() async {
    let value = lock.withLock { syncValue }
    await someAsyncWork()
    lock.withLock { updateSync(value) }
}
```

---

## When to Combine Primitives

### 1. Actor + Lock

**Use Case:** Synchronous file operations within async actor context

```swift
actor ScratchFileManager {
    private var metadata: [URL: FileMetadata] = [:]
    private let fileLock = NSLock()
    
    func writeBytes(_ data: Data, to url: URL, at offset: Int64) async throws {
        // Actor protects metadata
        let fileURL = metadata[url]?.localURL ?? createFile(for: url)
        
        // Lock protects actual file write (synchronous)
        fileLock.lock()
        defer { fileLock.unlock() }
        
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seek(toOffset: UInt64(offset))
        handle.write(data)  // Synchronous, no await
        try handle.close()
        
        // Back to actor protection for metadata
        metadata[url]?.size += Int64(data.count)
        metadata[url]?.lastModified = Date()
    }
}
```

**Why:**
- `FileHandle.write()` is synchronous (no await)
- Actor can be re-entered between operations
- Lock ensures atomic write without suspension
- Actor manages metadata, lock manages file I/O

**Pattern:**
```
Actor → Async operations + metadata
  ↓
Lock → Synchronous critical sections only
```

---

### 2. Actor + Serial Queue

**Use Case:** Interfacing with legacy GCD-based APIs

```swift
actor DownloadCoordinator {
    private let legacyQueue = DispatchQueue(label: "legacy-downloads")
    private var activeDownloads: Set<URL> = []
    
    func downloadVideo(from url: URL) async throws -> Data {
        // Actor tracks active downloads
        guard !activeDownloads.contains(url) else {
            throw DownloadError.alreadyDownloading
        }
        activeDownloads.insert(url)
        
        defer { 
            Task { await removeActiveDownload(url) }
        }
        
        // Bridge to legacy queue-based API
        return try await withCheckedThrowingContinuation { continuation in
            legacyQueue.async {
                // Legacy URLSession delegate that expects specific queue
                let session = self.createLegacySession()
                session.download(from: url) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
    
    private func removeActiveDownload(_ url: URL) {
        activeDownloads.remove(url)
    }
}
```

**Why:**
- Some APIs (URLSession delegates) expect specific queues
- Actor provides modern async/await interface
- Serial queue satisfies legacy API requirements

**Pattern:**
```
Actor → Modern async/await interface + state management
  ↓
Serial Queue → Legacy callback-based API execution
```

---

### 3. Serial Queue + Lock

**Use Case:** Shared state accessed from multiple contexts

```swift
class VideoCache {
    private let fileQueue = DispatchQueue(label: "file-operations")
    private let metadataLock = NSLock()
    private var cacheMetadata: [URL: CacheInfo] = [:]
    
    // Called from UI thread (synchronous)
    func getCacheInfo(for url: URL) -> CacheInfo? {
        metadataLock.lock()
        defer { metadataLock.unlock() }
        return cacheMetadata[url]
    }
    
    // Called from file queue (asynchronous)
    func writeFile(_ data: Data, to url: URL) {
        fileQueue.async {
            // Long file operation
            try? data.write(to: url)
            
            // Update metadata (lock needed for cross-context access)
            self.metadataLock.lock()
            self.cacheMetadata[url] = CacheInfo(
                size: data.count,
                lastModified: Date()
            )
            self.metadataLock.unlock()
        }
    }
    
    // Called from background download
    func updateProgress(for url: URL, progress: Double) {
        metadataLock.lock()
        cacheMetadata[url]?.progress = progress
        metadataLock.unlock()
    }
}
```

**Why:**
- Metadata accessed from multiple contexts (UI, file queue, network callbacks)
- Serial queue alone insufficient
- Lock provides fine-grained cross-context protection

**Pattern:**
```
Serial Queue → File operations
     ↓
Lock → Shared metadata accessed from multiple threads
```

**⚠️ Note:** For new code, prefer Actor instead of this pattern!

---

## Decision Matrix

| Scenario | Best Choice | Reason |
|----------|-------------|--------|
| **New async/await code** | Actor | Modern, safe, clean |
| **Async I/O operations** | Actor | Natural fit for suspension points |
| **Synchronous critical section** | Actor + Lock | Lock for non-suspending atomicity |
| **Legacy GCD interop** | Actor + Serial Queue | Bridge old and new |
| **Multiple access contexts (legacy)** | Serial Queue + Lock | When actor refactor not feasible |
| **Ordered processing** | Single Task with sequential awaits | Explicit control flow |
| **Parallel with limits** | TaskGroup with semaphore | Controlled concurrency |

### Quick Reference

```swift
// ✅ Prefer: Just Actor (simplest)
actor DataManager {
    func processData() async throws -> Data {
        // async operations with natural await points
    }
}

// ✅ Use: Actor + Lock (sync operations)
actor FileWriter {
    private let lock = NSLock()
    func writeSyncFile() {
        lock.withLock { /* sync file I/O */ }
    }
}

// ⚠️ Rare: Actor + Queue (legacy only)
actor LegacyBridge {
    private let queue = DispatchQueue(label: "legacy")
    // Only when required by legacy API
}

// ❌ Avoid: Queue + Lock (use Actor instead)
// Only if refactoring to Actor is not feasible
```

---

# Part 2: Application to Video Caching Problem

## The Problem

### Current Implementation Issues

From `VideoCacheManager.swift`:

```swift
func getAVPlayerFromPool(for url: URL) async -> AVPlayer {
    // Step 1: Create player with URL
    let playbackURL = isValidLocal ? localFileURL : url  // Line 63
    let player = AVPlayer(playerItem: playerItem)       // Line 71
    
    // Step 2: PARALLEL background download
    await handleVideoLocalityAndDownload(video, url)     // Line 76
    
    // ⚠️ PROBLEM: Downloads same video TWICE!
    // - AVPlayer streams from server
    // - Background task downloads same video to cache
    // Result: 100% bandwidth waste!
}
```

### Multiple Concurrent Calls

```swift
// User scrolls through video feed
Task { await cacheManager.getAVPlayerFromPool(video1) }
Task { await cacheManager.getAVPlayerFromPool(video2) }
Task { await cacheManager.getAVPlayerFromPool(video3) }
```

**Problems:**
1. **No execution order guarantee** - videos 1, 2, 3 might process in any order
2. **Duplicate downloads** - each video downloaded twice (stream + cache)
3. **Bandwidth competition** - multiple downloads compete for network
4. **No coordination** - downloads don't know about each other

---

## Why Order and Concurrency Matter

### Problem 1: Task Execution Order

```swift
// ❌ This does NOT guarantee video1 → video2 → video3
Task { await actor.getPlayer(for: video1) }
Task { await actor.getPlayer(for: video2) }
Task { await actor.getPlayer(for: video3) }

// Why? Because:
// 1. Three independent Tasks created
// 2. Scheduler decides when each runs (non-deterministic)
// 3. Tasks race to enter the actor
// 4. Actor serializes in arrival order (unpredictable)

// Possible execution: video2 → video1 → video3
```

### Problem 2: Bandwidth Waste

```swift
// Current flow for EACH video:
getAVPlayerFromPool(video1) {
    // Download #1: AVPlayer streaming
    let player = AVPlayer(url: remoteURL)  // 10 MB downloaded
    
    // Download #2: Background cache (PARALLEL!)
    Task {
        fileDownloader.download(from: remoteURL)  // Another 10 MB!
    }
    
    // Total: 20 MB for one 10 MB video!
}
```

### Problem 3: I/O Coordination

```swift
// Multiple videos downloading simultaneously:
// - video1 downloading to file1.mp4
// - video2 downloading to file2.mp4
// - video3 downloading to file3.mp4
//
// Need to ensure:
// ✓ File writes don't corrupt each other
// ✓ Disk space check is atomic
// ✓ LRU eviction doesn't delete while writing
// ✓ Bandwidth is managed (not overwhelming network)
```

---

## Solution Architecture

### Approach 1: Progressive Caching with Actor

**Eliminate duplicate downloads by making streaming and caching the same operation.**

```swift
// High-level architecture:
//
// AVPlayer requests bytes
//     ↓
// AVAssetResourceLoaderDelegate (intercepts)
//     ↓
// Check cache (Actor-protected)
//     ↓
// If cached → serve from local
// If not → download + cache + serve
//     ↓
// Single download serves both purposes!
```

### Component Design

```
┌─────────────────────────────────────────────────────────┐
│                 VideoCacheManager (Actor)               │
│  • Coordinates all caching operations                   │
│  • Thread-safe state management                         │
│  • Prevents duplicate downloads                         │
└─────────────────┬───────────────────────────────────────┘
                  │
         ┌────────┴────────┐
         │                 │
         ▼                 ▼
┌──────────────────┐  ┌──────────────────────────────┐
│ ResourceLoader   │  │ ScratchFileManager (Actor)   │
│ (Intercepts)     │  │  • Manages partial cache     │
│                  │  │  • Actor + Lock pattern      │
│  Delegates to    │  │  • File I/O coordination     │
│  ScratchFile     │  └──────────────────────────────┘
└──────────────────┘
```

---

## Implementation Examples

### Example 1: Progressive Cache Manager (Actor)

```swift
/// Main coordinator for progressive caching
/// Pattern: Actor for async operations and state management
@MainActor
class ProgressiveCacheManager: SHVideoCacheProtocol {
    private let scratchFileManager: ScratchFileManager
    private let httpDownloader: HTTPRangeDownloader
    
    // Track active operations to prevent duplicates
    private var activeOperations: Set<URL> = []
    
    init(
        scratchFileManager: ScratchFileManager,
        httpDownloader: HTTPRangeDownloader
    ) {
        self.scratchFileManager = scratchFileManager
        self.httpDownloader = httpDownloader
    }
    
    func getAVPlayer(for url: URL) async throws -> AVPlayer {
        // Actor ensures thread safety - only one task modifies state at a time
        
        // Check if already processing this video
        if activeOperations.contains(url) {
            // Wait for existing operation instead of starting duplicate
            return try await waitForExistingOperation(url)
        }
        
        // Mark as active
        activeOperations.insert(url)
        defer { activeOperations.remove(url) }
        
        // Convert to custom URL scheme for resource loader
        let customURL = convertToCustomScheme(url)
        
        // Create asset with resource loader delegate
        let asset = AVURLAsset(url: customURL)
        let delegate = VideoResourceLoaderDelegate(
            scratchFileManager: scratchFileManager,
            httpDownloader: httpDownloader
        )
        
        asset.resourceLoader.setDelegate(
            delegate,
            queue: DispatchQueue(label: "com.shophelp.resourceloader")
        )
        
        // Create player
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        // ✅ NO duplicate download!
        // Resource loader handles: stream + cache in one operation
        
        return player
    }
    
    private func convertToCustomScheme(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "caching-\(components.scheme ?? "https")"
        return components.url!
    }
}
```

**Why Actor:**
- Manages `activeOperations` state safely
- Prevents race conditions on duplicate checks
- Natural fit for async operations
- Clean, modern Swift concurrency

---

### Example 2: Scratch File Manager (Actor + Lock)

```swift
/// Manages partial cache files with byte-range tracking
/// Pattern: Actor + Lock for synchronous file I/O
actor ScratchFileManager {
    
    struct ScratchFile {
        let originalURL: URL
        let localURL: URL
        var cachedRanges: [Range<Int64>]
        var totalSize: Int64
        var lastAccessDate: Date
    }
    
    private var scratchFiles: [URL: ScratchFile] = [:]
    private let fileLock = NSLock()  // For synchronous file I/O
    private let maxCacheSize: Int64 = 500 * 1024 * 1024 // 500 MB
    
    // MARK: - Read Operation (Actor + Lock)
    
    func getCachedData(for url: URL, range: Range<Int64>) async throws -> Data? {
        // Actor protects metadata access
        guard let scratchFile = scratchFiles[url] else {
            return nil
        }
        
        // Check if range is cached
        guard scratchFile.cachedRanges.contains(where: { $0.overlaps(range) }) else {
            return nil
        }
        
        // Lock for synchronous file read
        return try fileLock.withLock {
            let fileHandle = try FileHandle(forReadingFrom: scratchFile.localURL)
            defer { try? fileHandle.close() }
            
            try fileHandle.seek(toOffset: UInt64(range.lowerBound))
            return fileHandle.readData(ofLength: Int(range.count))
        }
        
        // Note: No await between lock acquire and release!
    }
    
    // MARK: - Write Operation (Actor + Lock)
    
    func cacheData(_ data: Data, for url: URL, range: Range<Int64>) async throws {
        // Actor protects metadata
        var scratchFile = scratchFiles[url] ?? try await createScratchFile(for: url)
        
        // Lock for synchronous file write
        try fileLock.withLock {
            let fileHandle = try FileHandle(forWritingTo: scratchFile.localURL)
            defer { try? fileHandle.close() }
            
            try fileHandle.seek(toOffset: UInt64(range.lowerBound))
            fileHandle.write(data)
            
            // Ensure data is written to disk
            fileHandle.synchronizeFile()
        }
        
        // Back to actor protection for metadata update
        scratchFile.cachedRanges = mergeRanges(scratchFile.cachedRanges + [range])
        scratchFile.lastAccessDate = Date()
        scratchFiles[url] = scratchFile
        
        // Check cache capacity (actor-protected operation)
        await evictIfNeeded()
    }
    
    // MARK: - Helper Methods
    
    private func mergeRanges(_ ranges: [Range<Int64>]) -> [Range<Int64>] {
        // Merge overlapping ranges
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int64>] = []
        
        for range in sorted {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        
        return merged
    }
    
    private func evictIfNeeded() async {
        let totalSize = scratchFiles.values.reduce(0) { $0 + $1.totalSize }
        guard totalSize > maxCacheSize else { return }
        
        // LRU eviction (actor-protected)
        let sortedByAccess = scratchFiles.values.sorted {
            $0.lastAccessDate < $1.lastAccessDate
        }
        
        for file in sortedByAccess {
            // Delete file with lock
            fileLock.withLock {
                try? FileManager.default.removeItem(at: file.localURL)
            }
            
            // Update metadata (actor-protected)
            scratchFiles.removeValue(forKey: file.originalURL)
            
            let newTotal = scratchFiles.values.reduce(0) { $0 + $1.totalSize }
            if newTotal <= maxCacheSize {
                break
            }
        }
    }
    
    private func createScratchFile(for url: URL) async throws -> ScratchFile {
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SHVideoScratch")
        
        try FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
        
        let fileName = url.absoluteString
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "/", with: "_") ?? UUID().uuidString
        
        let localURL = cacheDir.appendingPathComponent(fileName)
        
        // Create empty file with lock
        try fileLock.withLock {
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }
        
        let scratchFile = ScratchFile(
            originalURL: url,
            localURL: localURL,
            cachedRanges: [],
            totalSize: 0,
            lastAccessDate: Date()
        )
        
        scratchFiles[url] = scratchFile
        return scratchFile
    }
}
```

**Why Actor + Lock:**
- **Actor** manages metadata (`scratchFiles`, `cachedRanges`, `lastAccessDate`)
- **Lock** protects synchronous file I/O (`FileHandle` operations)
- No `await` between lock acquire/release (avoids deadlock)
- Clean separation: actor for async, lock for sync critical sections

---

### Example 3: HTTP Range Downloader (Actor)

```swift
/// Downloads byte ranges from remote server
/// Pattern: Pure Actor (all operations are async)
actor HTTPRangeDownloader {
    private let session: URLSession
    private var activeRequests: [UUID: URLSessionDataTask] = [:]
    
    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }
    
    func downloadRange(from url: URL, range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
            forHTTPHeaderField: "Range"
        )
        
        let requestID = UUID()
        
        // Download with async/await
        let (data, response) = try await session.data(for: request)
        
        // Validate response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse
        }
        
        // Check for 206 Partial Content or 200 OK
        guard httpResponse.statusCode == 206 || httpResponse.statusCode == 200 else {
            throw DownloadError.httpError(httpResponse.statusCode)
        }
        
        return data
    }
    
    func getContentLength(for url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              let contentLength = httpResponse.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(contentLength) else {
            throw DownloadError.missingContentLength
        }
        
        return length
    }
    
    func cancelRequest(for id: UUID) {
        activeRequests[id]?.cancel()
        activeRequests.removeValue(forKey: id)
    }
}

enum DownloadError: Error {
    case invalidResponse
    case httpError(Int)
    case missingContentLength
}
```

**Why Pure Actor:**
- All operations are naturally async (`session.data`)
- No synchronous I/O (no lock needed)
- Actor provides thread safety for `activeRequests`
- Clean async/await throughout

---

### Example 4: Resource Loader Delegate (Non-isolated)

```swift
/// Intercepts AVPlayer's network requests
/// Pattern: Non-isolated class that delegates to actors
class VideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    private let scratchFileManager: ScratchFileManager
    private let httpDownloader: HTTPRangeDownloader
    
    init(
        scratchFileManager: ScratchFileManager,
        httpDownloader: HTTPRangeDownloader
    ) {
        self.scratchFileManager = scratchFileManager
        self.httpDownloader = httpDownloader
        super.init()
    }
    
    // Called by AVFoundation on delegate queue
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Spawn async task to handle request
        Task {
            await handleRequest(loadingRequest)
        }
        return true  // We'll handle this request
    }
    
    private func handleRequest(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        guard let url = loadingRequest.request.url,
              let originalURL = convertFromCustomScheme(url) else {
            loadingRequest.finishLoading(with: NSError(
                domain: "VideoResourceLoader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]
            ))
            return
        }
        
        do {
            // Handle content info request
            if let infoRequest = loadingRequest.contentInformationRequest {
                try await handleContentInfoRequest(infoRequest, for: originalURL)
            }
            
            // Handle data request
            if let dataRequest = loadingRequest.dataRequest {
                try await handleDataRequest(dataRequest, for: originalURL)
            }
            
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }
    
    private func handleContentInfoRequest(
        _ request: AVAssetResourceLoadingContentInformationRequest,
        for url: URL
    ) async throws {
        // Delegate to actor
        let contentLength = try await httpDownloader.getContentLength(for: url)
        
        request.contentLength = contentLength
        request.isByteRangeAccessSupported = true
        request.contentType = "video/mp4"
    }
    
    private func handleDataRequest(
        _ request: AVAssetResourceLoadingDataRequest,
        for url: URL
    ) async throws {
        let requestedOffset = request.requestedOffset
        let requestedLength = request.requestedLength
        let range = requestedOffset..<(requestedOffset + Int64(requestedLength))
        
        // Try cache first (actor)
        if let cachedData = try await scratchFileManager.getCachedData(
            for: url,
            range: range
        ) {
            request.respond(with: cachedData)
            return
        }
        
        // Download and cache (actor)
        let data = try await httpDownloader.downloadRange(from: url, range: range)
        try await scratchFileManager.cacheData(data, for: url, range: range)
        
        // Serve to player
        request.respond(with: data)
    }
    
    private func convertFromCustomScheme(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = components?.scheme?.replacingOccurrences(
            of: "caching-",
            with: ""
        )
        return components?.url
    }
    
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Cancel any in-flight downloads
        Task {
            // Could add cancellation logic to httpDownloader
        }
    }
}
```

**Why Non-isolated:**
- `AVAssetResourceLoaderDelegate` called by AVFoundation on specific queue
- Delegates all actual work to actors
- Acts as bridge between AVFoundation and our actor-based architecture
- No state of its own (just coordinates between actors)

---

## Ensuring Sequential Processing

### Problem: Multiple Videos Loading

```swift
// User scrolls through feed
Task { await manager.getAVPlayer(for: video1) }
Task { await manager.getAVPlayer(for: video2) }
Task { await manager.getAVPlayer(for: video3) }

// ⚠️ These execute in non-deterministic order!
```

### Solution 1: Single Task for Sequential

```swift
// ✅ Guaranteed order: video1 → video2 → video3
Task {
    let player1 = await manager.getAVPlayer(for: video1)
    let player2 = await manager.getAVPlayer(for: video2)
    let player3 = await manager.getAVPlayer(for: video3)
}
```

### Solution 2: TaskGroup with Ordering

```swift
// ✅ Controlled parallel execution
await withTaskGroup(of: AVPlayer.self) { group in
    group.addTask { await manager.getAVPlayer(for: video1) }
    await group.next()  // Wait for video1
    
    group.addTask { await manager.getAVPlayer(for: video2) }
    await group.next()  // Wait for video2
    
    group.addTask { await manager.getAVPlayer(for: video3) }
    await group.next()  // Wait for video3
}
```

### Solution 3: Internal Queue in Actor

```swift
actor OrderedVideoCacheManager {
    private var pendingOperations: [(URL, CheckedContinuation<AVPlayer, Error>)] = []
    private var isProcessing = false
    
    func getAVPlayer(for url: URL) async throws -> AVPlayer {
        return try await withCheckedThrowingContinuation { continuation in
            pendingOperations.append((url, continuation))
            
            if !isProcessing {
                Task { await processQueue() }
            }
        }
    }
    
    private func processQueue() async {
        isProcessing = true
        
        while !pendingOperations.isEmpty {
            let (url, continuation) = pendingOperations.removeFirst()
            
            do {
                let player = try await createPlayer(for: url)
                continuation.resume(returning: player)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        
        isProcessing = false
    }
    
    private func createPlayer(for url: URL) async throws -> AVPlayer {
        // Actual player creation logic
        // ...
    }
}
```

### Solution 4: Bandwidth-Aware Parallel (Recommended)

```swift
actor BandwidthAwareCache {
    private var activeDownloads = 0
    private let maxConcurrent = 2  // Limit parallel downloads
    
    func getAVPlayer(for url: URL) async throws -> AVPlayer {
        // Wait if too many active downloads
        while activeDownloads >= maxConcurrent {
            await Task.yield()
        }
        
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        
        // Progressive caching handles the rest
        return try await createPlayerWithProgressiveCache(url)
    }
}
```

**Why Solution 4:**
- ✅ Allows parallelism (better UX)
- ✅ Limits bandwidth consumption
- ✅ Progressive cache eliminates duplicates
- ✅ Actor ensures thread safety
- ✅ No complex queue management

---

## Common Pitfalls

### Pitfall 1: Holding Lock Across Await

```swift
// ❌ DEADLY: Deadlock guaranteed!
func badWriteFile() async {
    lock.lock()
    let data = await downloadData()  // ⚠️ SUSPENSION with lock held!
    writeToFile(data)
    lock.unlock()
}

// ✅ GOOD: Lock only sync operations
func goodWriteFile() async {
    let data = await downloadData()  // No lock during download
    
    lock.withLock {
        writeToFile(data)  // Lock only file write
    }
}
```

### Pitfall 2: Assuming Actor Guarantees Order

```swift
actor VideoCache {
    func loadVideo(_ url: URL) async { /* ... */ }
}

let cache = VideoCache()

// ❌ WRONG: Assumes video1 → video2 → video3
Task { await cache.loadVideo(video1) }
Task { await cache.loadVideo(video2) }
Task { await cache.loadVideo(video3) }

// ✅ RIGHT: Explicit ordering
Task {
    await cache.loadVideo(video1)
    await cache.loadVideo(video2)
    await cache.loadVideo(video3)
}
```

### Pitfall 3: Not Preventing Duplicate Operations

```swift
// ❌ BAD: Multiple calls for same URL download twice
actor BadCache {
    func download(_ url: URL) async throws -> Data {
        return try await httpClient.download(url)
    }
}

// Called simultaneously:
// Task { await cache.download(sameURL) }  // Download 1
// Task { await cache.download(sameURL) }  // Download 2 (duplicate!)

// ✅ GOOD: Track active operations
actor GoodCache {
    private var activeDownloads: [URL: Task<Data, Error>] = [:]
    
    func download(_ url: URL) async throws -> Data {
        // Return existing task if already downloading
        if let existingTask = activeDownloads[url] {
            return try await existingTask.value
        }
        
        // Create new task
        let task = Task<Data, Error> {
            defer { activeDownloads.removeValue(forKey: url) }
            return try await httpClient.download(url)
        }
        
        activeDownloads[url] = task
        return try await task.value
    }
}
```

### Pitfall 4: File Handle Leaks

```swift
// ❌ BAD: File handle leaked on error
func badRead() throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    let data = handle.readDataToEndOfFile()
    
    if data.isEmpty {
        throw ReadError.emptyFile  // ⚠️ Leak: handle not closed!
    }
    
    try handle.close()
    return data
}

// ✅ GOOD: Always close with defer
func goodRead() throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }  // Always closes
    
    let data = handle.readDataToEndOfFile()
    
    if data.isEmpty {
        throw ReadError.emptyFile
    }
    
    return data
}
```

### Pitfall 5: Ignoring Re-entrancy

```swift
actor BadCounter {
    var count = 0
    
    func increment() async {
        let current = count
        await Task.yield()  // ⚠️ Suspension point!
        count = current + 1  // ⚠️ Another task may have modified count!
    }
}

// Result: Race condition even with actor!

actor GoodCounter {
    var count = 0
    
    // ✅ Option 1: No suspension point
    func increment() {
        count += 1
    }
    
    // ✅ Option 2: Re-read after suspension
    func incrementAsync() async {
        await Task.yield()
        count += 1  // Read count again after suspension
    }
    
    // ✅ Option 3: Use lock for critical section
    private let lock = NSLock()
    
    func incrementWithLock() async {
        await Task.yield()
        lock.withLock {
            count += 1
        }
    }
}
```

---

## Summary: Best Practices for Video Caching

### Architecture Pattern

```
ProgressiveCacheManager (Actor)
    ├─ State management: activeOperations, configuration
    ├─ Coordination: prevent duplicates, manage lifecycle
    └─ Delegates to specialized actors
            │
            ├─ ScratchFileManager (Actor + Lock)
            │   ├─ Actor: metadata, cached ranges, LRU
            │   └─ Lock: synchronous file I/O
            │
            ├─ HTTPRangeDownloader (Actor)
            │   └─ Actor: async network operations
            │
            └─ ResourceLoaderDelegate (Non-isolated)
                └─ Bridges AVFoundation to actors
```

### Key Principles

1. **Use Actor as Default** - Modern, safe, clean for async operations
2. **Add Lock for Sync I/O** - FileHandle operations need atomicity
3. **Never Lock Across Await** - Causes deadlocks
4. **Explicit Ordering** - Use single Task or TaskGroup when order matters
5. **Prevent Duplicates** - Track active operations in actor state
6. **Limit Concurrency** - Use counter to prevent bandwidth overload
7. **Always Close Resources** - Use `defer` for file handles

### Migration Strategy

```swift
// Phase 1: Add progressive cache alongside legacy
if featureFlags.progressiveCaching {
    return await progressiveCache.getPlayer(for: url)
} else {
    return await legacyCache.getPlayer(for: url)
}

// Phase 2: Gradual rollout with monitoring
// Phase 3: Full migration once validated
```

---

## Further Reading

- [Swift Concurrency Documentation](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [AVAssetResourceLoaderDelegate Documentation](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate)
- [video-player-improvement-proposal.md](./video-player-improvement-proposal.md) - Full implementation proposal
- [current-video-flow-detailed.md](./current-video-flow-detailed.md) - Current architecture

---

**Document Owner:** iOS Engineering Team  
**Review Cycle:** Quarterly  
**Last Reviewed:** 2025-12-28






