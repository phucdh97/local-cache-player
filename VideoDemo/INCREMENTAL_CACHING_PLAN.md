---
name: Incremental Chunk Caching
overview: Implement progressive caching that saves downloaded chunks periodically during download instead of only on request completion, preventing data loss when requests are cancelled or the app is closed.
todos:
  - id: add-properties
    content: Add lastSavedOffset and incrementalSaveThreshold properties to ResourceLoaderRequest
    status: pending
  - id: implement-incremental-save
    content: Create saveIncrementalChunk() method to handle periodic saves
    status: pending
  - id: modify-didReceive
    content: Update urlSession(_:dataTask:didReceive:) to check threshold and trigger saves
    status: pending
  - id: update-completion
    content: Modify didCompleteWithError to save only remaining unsaved data
    status: pending
  - id: update-cancel
    content: Modify cancel() to save accumulated data before cancelling request
    status: pending
  - id: test-incremental
    content: Test with download and early stop to verify data is saved progressively
    status: pending
isProject: false
---

# Incremental Chunk Caching Implementation

## Problem Analysis

Currently, video data is only saved when a URLSession request completes (`didCompleteWithError`). When users:

- Stop playing a video
- Close the app
- Switch to another video

Active network requests are cancelled, and all accumulated data in memory (up to 8MB observed) is lost. Only completed requests get saved (205KB observed vs 8MB downloaded).

**Current Flow:**

```
Download starts → Accumulate in memory → Request completes → Save to cache
                                      ↓
                              Request cancelled → Data lost!
```

**New Flow:**

```
Download starts → Accumulate in memory → Threshold reached → Save chunk
                                      → Continue accumulating...
                                      → Threshold reached → Save chunk
                                      → Request completes/cancels → Save remainder
```

## Implementation Strategy

### 1. Add Incremental Save Threshold

Add a configurable threshold to [`ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift):

**Location:** Add properties at line ~52

```swift
private(set) var downloadedData: Data = Data()
private var lastSavedOffset: Int = 0  // Track what we've saved
private let incrementalSaveThreshold = 512 * 1024  // 512KB threshold
```

**Rationale:**

- 512KB balances disk writes vs data safety
- Small enough to minimize loss (max 512KB on cancel)
- Large enough to avoid excessive disk I/O
- Typical video chunk sizes are 10-100KB, so saves every ~5-50 chunks

### 2. Implement Incremental Save Logic

Modify `urlSession(_:dataTask:didReceive:)` in [`ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift):

**Current (line 134-149):**

```swift
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard self.type == .dataRequest else { return }
    
    self.loaderQueue.async {
        self.delegate?.dataRequestDidReceive(self, data)
        self.downloadedData.append(data)
        print("📥 Received chunk: ...")
    }
}
```

**New implementation:**

```swift
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard self.type == .dataRequest else { return }
    
    self.loaderQueue.async {
        // 1. Stream to AVPlayer immediately
        self.delegate?.dataRequestDidReceive(self, data)
        
        // 2. Accumulate for caching
        self.downloadedData.append(data)
        
        print("📥 Received chunk: \(formatBytes(data.count)), accumulated: \(formatBytes(self.downloadedData.count))")
        
        // 3. Check if we should save incrementally
        let unsavedBytes = self.downloadedData.count - self.lastSavedOffset
        if unsavedBytes >= self.incrementalSaveThreshold {
            self.saveIncrementalChunk()
        }
    }
}
```

### 3. Add Incremental Save Method

Add new method to [`ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift):

**Location:** After `cancel()` method, before URLSessionDataDelegate section

```swift
private func saveIncrementalChunk() {
    guard let requestStartOffset = self.requestRange?.start else { return }
    
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
    guard unsavedData.count > 0 else { return }
    
    let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
    
    print("💾 Incremental save: \(formatBytes(unsavedData.count)) at offset \(actualOffset) for \(self.originalURL.lastPathComponent)")
    
    self.assetDataManager?.saveDownloadedData(Data(unsavedData), offset: actualOffset)
    self.lastSavedOffset = self.downloadedData.count
    
    print("📊 Progress: saved \(formatBytes(self.lastSavedOffset)) / \(formatBytes(self.downloadedData.count))")
}
```

**Key Points:**

- Saves only the unsaved portion (`suffix(from: lastSavedOffset)`)
- Calculates correct offset: `requestStartOffset + lastSavedOffset`
- Updates `lastSavedOffset` to track progress
- Thread-safe (already on `loaderQueue`)

### 4. Update Completion Handler

Modify `didCompleteWithError` in [`ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift):

**Current (line 209-215):**

```swift
// SAVE TO CACHE
if let offset = self.requestRange?.start, self.downloadedData.count > 0 {
    print("💾 Saving \(formatBytes(self.downloadedData.count)) ...")
    self.assetDataManager?.saveDownloadedData(self.downloadedData, offset: Int(offset))
}
```

**New implementation:**

```swift
// SAVE REMAINING DATA TO CACHE
if let requestStartOffset = self.requestRange?.start {
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
    if unsavedData.count > 0 {
        let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
        print("💾 Final save: \(formatBytes(unsavedData.count)) at offset \(actualOffset) for \(self.originalURL.lastPathComponent)")
        self.assetDataManager?.saveDownloadedData(Data(unsavedData), offset: actualOffset)
        print("✅ Total saved: \(formatBytes(self.downloadedData.count)) for this request")
    } else {
        print("✅ All data already saved incrementally (\(formatBytes(self.downloadedData.count)))")
    }
} else if self.downloadedData.count == 0 {
    print("⚠️ No data to save for \(self.originalURL.lastPathComponent)")
}
```

**Why this works:**

- Saves only what hasn't been saved yet
- Works even if request was cancelled (saves partial data)
- Handles edge case where all data was already saved incrementally

### 5. Handle Request Cancellation

Update `cancel()` method in [`ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift):

**Current (line 128-130):**

```swift
func cancel() {
    self.isCancelled = true
}
```

**New implementation:**

```swift
func cancel() {
    self.loaderQueue.async { [weak self] in
        guard let self = self else { return }
        
        // Save any unsaved data before cancelling
        if self.type == .dataRequest {
            let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
            if unsavedData.count > 0, let requestStartOffset = self.requestRange?.start {
                let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
                print("💾 Cancel save: \(formatBytes(unsavedData.count)) at offset \(actualOffset) for \(self.originalURL.lastPathComponent)")
                self.assetDataManager?.saveDownloadedData(Data(unsavedData), offset: actualOffset)
                print("✅ Saved \(formatBytes(self.downloadedData.count)) before cancel")
            }
        }
        
        self.isCancelled = true
    }
}
```

**Critical for data preservation:**

- Saves accumulated data when request is explicitly cancelled
- Prevents data loss when user stops video or switches content
- Runs on `loaderQueue` for thread safety

## Expected Behavior After Implementation

### Scenario 1: User downloads 8MB then stops

**Before:** Only 205KB saved (completed requests only)

**After:** ~7.5-8MB saved (multiple incremental saves + final save)

### Scenario 2: Long download (50MB)

**Before:** 0 bytes saved if cancelled, or 50MB saved all at once if completed

**After:** Progressive saves every 512KB, data accumulates in cache during download

### Scenario 3: App crashes during download

**Before:** All in-memory data lost

**After:** Most data saved (loses max 512KB per active request)

## New Log Output

```
📥 Received chunk: 43.75 KB, accumulated: 498.23 KB
📥 Received chunk: 21.48 KB, accumulated: 519.71 KB
💾 Incremental save: 519.71 KB at offset 65536 for BigBuckBunny.mp4
🔄 Saving chunk: 519.71 KB at offset 65536 for BigBuckBunny.mp4
💾 Stored chunk with key: BigBuckBunny.mp4_chunk_65536, size: 519.71 KB
📌 Added chunk offset 64.00 KB, total offsets: 3
📊 Progress: saved 519.71 KB / 519.71 KB
... (continues downloading)
📥 Received chunk: 10.94 KB, accumulated: 1.02 MB
💾 Incremental save: 512.00 KB at offset 585307 for BigBuckBunny.mp4
... (user stops video)
💾 Cancel save: 8.96 KB at offset 1097307 for BigBuckBunny.mp4
✅ Saved 1.02 MB before cancel
```

## Configuration Options

The threshold can be adjusted based on needs:

| Threshold | Saves Per Request | Data Loss Risk | Disk I/O |

|-----------|------------------|----------------|----------|

| 256KB | More frequent | Lower (~256KB max) | Higher |

| 512KB | Balanced | Medium (~512KB max) | Medium |

| 1MB | Less frequent | Higher (~1MB max) | Lower |

**Recommendation:** Start with 512KB, can be made configurable later if needed.

## Files Modified

1. [`VideoDemo/VideoDemo/ResourceLoaderRequest.swift`](VideoDemo/VideoDemo/ResourceLoaderRequest.swift)

   - Add properties: `lastSavedOffset`, `incrementalSaveThreshold`
   - Add method: `saveIncrementalChunk()`
   - Modify: `urlSession(_:dataTask:didReceive:)` - add incremental save check
   - Modify: `didCompleteWithError` - save only remaining data
   - Modify: `cancel()` - save unsaved data before cancelling

## Testing Verification

After implementation:

1. Play video for 10 seconds
2. Check console for "💾 Incremental save" logs (should see multiple)
3. Stop video before completion
4. Check cache size - should be close to accumulated size
5. Launch offline - verify cached data is retrievable
6. Expected: ~95% of downloaded data saved (vs ~2-5% currently)