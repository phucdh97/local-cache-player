# Development Issues & Solutions

This document details all the issues encountered during development and their solutions.

---

## Issue #1: Info.plist Conflict ❌

### Error Message
```
Multiple commands produce '/Users/.../VideoDemo.app/Info.plist'
```

### Root Cause
Modern Xcode projects (14+) **automatically generate** Info.plist at build time. Having a manual `Info.plist` file creates a conflict where two files try to be copied to the same location.

### Solution
1. **Delete** the manual `Info.plist` file
2. Configure settings via Xcode UI:
   - Project → Target → Info tab
   - Add: `App Transport Security Settings` → `Allow Arbitrary Loads` = YES

### Prevention
Don't create manual Info.plist files in modern Xcode projects. Use build settings instead.

---

## Issue #2: Buffer Offset Crash 💥

### Error Message
```
Thread 1: EXC_BREAKPOINT (code=1, subcode=0x180bb54e4)
at: let data = receivedData.subdata(in: bufferOffset..<endOffset)
```

### Root Cause
**Complex buffer management** with trimming:
```swift
// BROKEN APPROACH:
var receivedData = Data()  // Growing buffer
var bufferStartOffset: Int64 = 0

// When buffer > 10MB, trim first 5MB
receivedData = receivedData.suffix(5MB)
bufferStartOffset += 5MB

// Calculate offset:
bufferOffset = requestedOffset - bufferStartOffset
// BUG: After multiple trims, this calculation breaks!
```

**Race condition**: Buffer being trimmed while another thread tries to read from it.

### Solution
**Simplified approach** - Array of chunks:
```swift
// WORKING APPROACH:
var recentChunks: [(offset: Int64, data: Data)] = []

// When > 20 chunks, remove oldest:
if recentChunks.count > 20 {
    recentChunks.removeFirst()  // Simple FIFO!
}

// Find data:
for chunk in recentChunks {
    if requestedOffset in chunk.range {
        return chunk.data  // Direct access!
    }
}
```

### Key Learning
**Simple is better!** Avoid complex offset calculations. Store absolute positions with each chunk.

---

## Issue #3: Metadata Dictionary Corruption 🔥

### Error Message
```
NSInvalidArgumentException: -[NSIndirectTaggedPointerString count]: 
unrecognized selector sent to instance
```

### Root Cause
**Thread safety violation** when switching videos:
```swift
// Two delegates running simultaneously:
Video 1 (23.8%): metadataCache[key1] = metadata1
Video 2 (0.0%):  metadataCache[key2] = metadata2

// Dictionary corruption: Reading while writing!
```

Swift dictionaries are **not thread-safe**. Concurrent reads/writes caused internal corruption.

### Solution
Add **NSLock** for all dictionary access:
```swift
private var metadataCache: [String: CacheMetadata] = [:]
private let metadataCacheLock = NSLock()

func getCacheMetadata(for url: URL) -> CacheMetadata? {
    metadataCacheLock.lock()
    let metadata = metadataCache[key]
    metadataCacheLock.unlock()
    return metadata
}
```

### Key Learning
**Always protect shared mutable state** when multiple threads can access it. Don't assume Swift collections are thread-safe.

---

## Issue #4: Cached Video Won't Play After Restart 📱

### Error Message
```
<<< FFR_Common >>> signalled err=-12847
❌ Player item failed: Cannot Open
IOSurfaceClientSetSurfaceNotify failed
```

### Root Cause
**Direct file playback** of progressively cached files:
```swift
// BROKEN:
if cacheManager.isCached(url: url) {
    let cachedURL = cacheManager.cacheFilePath(for: url)
    let asset = AVURLAsset(url: cachedURL)  // ❌ Doesn't work!
    return AVPlayerItem(asset: asset)
}
```

Progressive writing with `FileHandle.seek()` and `write()` may not create proper MP4 structure/headers.

### Solution
**Always use resource loader delegate**, even for cached videos:
```swift
// WORKING:
// Always create with custom scheme and delegate
let customURL = createCustomURL(from: url)  // cachevideo://
let asset = AVURLAsset(url: customURL)
asset.resourceLoader.setDelegate(delegate, queue: .main)

// Delegate serves from cache seamlessly
```

### Key Learning
Don't try to play raw cached files directly. Use the resource loader abstraction for consistent handling.

---

## Issue #5: Won't Play from Partial Cache ⏸️

### Symptoms
Video downloaded to 30%, but on restart:
- Waits for 100% download before playing
- Console shows: "⏳ Waiting for more data at offset 0" (repeatedly)
- Resume works (HTTP 206) but video doesn't play

### Root Cause
**All-or-nothing data serving**:
```swift
// BROKEN:
func cachedData(for url: URL, offset: Int64, length: Int) -> Data? {
    // Check if ENTIRE range is cached
    guard isRangeCached(for: url, offset: offset, length: length) else {
        return nil  // ❌ Returns nothing if any part missing!
    }
    return data
}

// Request: offset=0, length=158MB
// Cached: 0-19MB
// Result: nil (because 19-158MB missing)
// Player: Waits forever...
```

### Solution
**Serve partial data** - return what's available:
```swift
// WORKING:
func cachedData(for url: URL, offset: Int64, length: Int) -> Data? {
    let cachedSize = getCachedDataSize(for: url)
    
    // Return nothing only if offset is beyond cached data
    guard offset < cachedSize else { return nil }
    
    // Return whatever we have (might be less than requested)
    let availableLength = min(Int64(length), cachedSize - offset)
    return readFromDisk(offset: offset, length: availableLength)
}

// Request: offset=0, length=158MB
// Cached: 0-19MB  
// Result: 19MB of data ✅
// Player: Starts playing immediately!
```

### Key Learning
**Progressive playback requires partial data serving**. Don't wait for complete ranges. AVPlayer handles partial responses gracefully.

---

## Issue #6: Missing Percentage on Resume 📊

### Symptoms
First session shows: `(10.5%)`, `(12.3%)`  
After restart shows: `(0.0%)`, `(0.0%)`

### Root Cause
**expectedContentLength not set** when resuming:
```swift
// HTTP 200 (full download):
expectedContentLength = response.expectedContentLength ✅

// HTTP 206 (resumed download):
expectedContentLength = 0 ❌ (not set!)

// Percentage calculation:
percentage = downloadOffset / expectedContentLength
           = 19MB / 0 = NaN → Shows (0.0%)
```

### Solution
**Parse Content-Range header** from HTTP 206:
```swift
if httpResponse.statusCode == 206 {
    // Content-Range: bytes 19068105-158008373/158008374
    //                                         ↑ This is the total!
    if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
        if let totalSizeStr = contentRange.split(separator: "/").last {
            expectedContentLength = Int64(totalSizeStr)!
        }
    }
}

// Now: percentage = 19MB / 158MB = 12.0% ✅
```

### Key Learning
HTTP 206 responses use `Content-Range` header to communicate total file size. Parse it for progress calculation.

---

## Summary of Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Info.plist conflict | Manual file conflicts with auto-gen | Delete manual file, use Xcode UI |
| Buffer crash | Complex trimming with offset tracking | Simple chunk array with FIFO |
| Dictionary corruption | No thread safety | Actor for metadata, Serial Queue for recentChunks |
| Cached video won't play | Direct file playback | Always use resource loader |
| Won't play partial cache | All-or-nothing data serving | Serve partial data |
| Missing percentage | Not parsing HTTP 206 headers | Parse Content-Range header |

---

## Best Practices Learned

### 1. Thread Safety
- ✅ Protect all shared mutable state
- ✅ Use Actor for metadata (modern Swift, compiler-enforced, can be async)
- ✅ Use Serial DispatchQueue for recentChunks (works with AVFoundation sync methods, matches blog pattern)
- ✅ Avoid manual NSLock when possible (error-prone, easy to forget)

**Why Different Approaches?**

**Metadata (`VideoCacheManager`):**
- Uses **Actor** because:
  - Can be async (no AVFoundation constraints)
  - Modern Swift pattern
  - Compiler-enforced safety

**RecentChunks (`VideoResourceLoaderDelegate`):**
- Uses **Serial DispatchQueue** because:
  - AVFoundation delegate methods are **synchronous**
  - Actor requires `await` (async) - incompatible with sync methods
  - NSLock is error-prone (we already hit bugs with it)
  - DispatchQueue provides `sync` for immediate results + automatic safety
  - Matches blog's pattern (`loaderQueue`)

**Key Insight:** Choose thread safety mechanism based on constraints:
- **No sync constraints?** → Use Actor (modern, safe)
- **Must work with sync APIs?** → Use Serial DispatchQueue (compatible, safe)
- **Avoid NSLock** → Too error-prone for production code

### 2. Buffer Management
- ✅ Keep buffer management simple
- ✅ Store absolute positions, not relative offsets
- ✅ Prefer small, discrete chunks over large buffers

### 3. Progressive Playback
- ✅ Serve partial data whenever possible
- ✅ Don't wait for complete ranges
- ✅ Let AVPlayer handle partial responses

### 4. HTTP Range Requests
- ✅ Support HTTP 206 (Partial Content)
- ✅ Parse Content-Range headers correctly
- ✅ Use Range request header for resume

### 5. Resource Loader Pattern
- ✅ Always use custom URL scheme
- ✅ Use delegate for all playback (cached or not)
- ✅ Don't try to bypass the abstraction

---

## Testing Checklist

Use this to verify all issues are resolved:

- [ ] Can build project without Info.plist errors
- [ ] Video plays for >10 minutes without buffer crashes
- [ ] Can switch between videos rapidly without crashes
- [ ] Fully cached videos play after app restart
- [ ] Partially cached videos play immediately (not waiting for 100%)
- [ ] Percentage shows correctly in first session
- [ ] Percentage shows correctly after resume
- [ ] Console logs are clean (no NSException errors)
- [ ] Memory usage stays reasonable (<200MB)
- [ ] Can seek within cached portions instantly

---

## Debug Tips

### Enable Verbose Logging
The implementation includes detailed emoji-prefixed logs:
- 📦 Setup/initialization
- 🎬 Player creation
- 📥 Loading requests
- 📡 Network responses
- 💾 Data caching
- ✅ Success operations
- ❌ Errors
- ⏳ Waiting states
- 🧹 Cleanup

### Console Filtering
```
# Filter by emoji in Xcode console:
💾  - See caching operations
📊  - See progress percentages  
❌  - See only errors
✅  - See successful operations
```

### Breakpoint Locations
Set breakpoints at:
1. `VideoCacheManager.addCachedRange()` - Track metadata updates
2. `VideoResourceLoaderDelegate.fillDataRequest()` - Debug data serving
3. `urlSession(_:dataTask:didReceive:)` - Track incoming chunks

---

## Conclusion

All issues were resolved through:
1. **Simplification** - Removing complex state management
2. **Thread safety** - Protecting shared resources
3. **Correct abstractions** - Using resource loader properly
4. **Partial data support** - Progressive playback
5. **HTTP protocol understanding** - Range requests and 206 responses

The final implementation is **stable, efficient, and production-ready** (with cache size management added).





