# Video Caching Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         ContentView                              │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐              │
│  │  Video 1   │  │  Video 2   │  │  Video 3     │              │
│  └──────┬─────┘  └──────┬─────┘  └──────┬───────┘              │
│         │                │                │                       │
│         └────────────────┴────────────────┘                      │
│                          │                                        │
└──────────────────────────┼────────────────────────────────────┘
                           │ URL
                           ▼
            ┌──────────────────────────────┐
            │    CachedVideoPlayer         │
            │  ┌────────────────────────┐  │
            │  │   VideoPlayerViewModel │  │
            │  └───────────┬────────────┘  │
            └──────────────┼───────────────┘
                           │
                           ▼
            ┌──────────────────────────────┐
            │  CachedVideoPlayerManager    │
            │  • Convert URL scheme        │
            │  • Create AVPlayerItem       │
            └──────────────┬───────────────┘
                           │
                           ▼
            ┌──────────────────────────────┐
            │       AVPlayerItem           │
            │         (AVPlayer)           │
            └──────────────┬───────────────┘
                           │
                           │ Resource Request
                           ▼
        ┌───────────────────────────────────────┐
        │  VideoResourceLoaderDelegate          │
        │  • shouldWaitForLoadingOfRequested... │
        │  • didCancel loadingRequest           │
        └───────────────┬───────────────────────┘
                        │
            ┌───────────┴────────────┐
            │                        │
            ▼                        ▼
    ┌──────────────┐        ┌──────────────┐
    │ Info Request │        │ Data Request │
    │              │        │              │
    │ • Length     │        │ • Offset     │
    │ • Type       │        │ • Length     │
    │ • ByteRange  │        │ • Data       │
    └──────┬───────┘        └──────┬───────┘
           │                       │
           └───────────┬───────────┘
                       │
                       ▼
        ┌──────────────────────────────┐
        │    VideoCacheManager         │
        │                              │
        │  ┌────────────────────────┐  │
        │  │   Memory Cache         │  │
        │  │   (NSCache)            │  │
        │  │   • Fast access        │  │
        │  │   • 100MB limit        │  │
        │  └────────────────────────┘  │
        │                              │
        │  ┌────────────────────────┐  │
        │  │   Disk Cache           │  │
        │  │   (FileManager)        │  │
        │  │   • Persistent         │  │
        │  │   • Unlimited          │  │
        │  └────────────────────────┘  │
        └──────────┬───────────────────┘
                   │
                   ▼
        ┌──────────────────┐
        │   Cache Hit?     │
        └────┬─────────┬───┘
             │ YES     │ NO
             │         │
             ▼         ▼
    ┌────────────┐  ┌────────────────┐
    │   Serve    │  │   Download     │
    │   Cached   │  │   from URL     │
    │   Data     │  │                │
    └────────────┘  └────────┬───────┘
                             │
                             ▼
                    ┌─────────────────┐
                    │  Save to Cache  │
                    └─────────────────┘
```

## Data Flow Sequence

### First Time Playing (Not Cached)

```
1. User selects video
   ↓
2. CachedVideoPlayer created with URL
   ↓
3. CachedVideoPlayerManager.createPlayerItem()
   ↓
4. Check if cached: NO
   ↓
5. Convert URL: http:// → cachevideo://
   ↓
6. Create AVURLAsset with custom URL
   ↓
7. Set VideoResourceLoaderDelegate
   ↓
8. AVPlayer starts requesting data
   ↓
9. Delegate receives loading request
   ↓
10. Check cache: NOT FOUND
    ↓
11. Start URLSession download
    ↓
12. Receive data chunks
    ↓
13. Save to cache (memory + disk)
    ↓
14. Respond to AVPlayer with data
    ↓
15. Video plays while downloading
```

### Second Time Playing (Cached)

```
1. User selects same video
   ↓
2. CachedVideoPlayer created with URL
   ↓
3. CachedVideoPlayerManager.createPlayerItem()
   ↓
4. Check if cached: YES
   ↓
5. Create AVPlayerItem with local file URL
   ↓
6. AVPlayer plays immediately
   ↓
7. No network request needed
   ↓
8. Instant playback ✨
```

## Component Responsibilities

### 1. VideoCacheManager
**Role**: Storage management
- ✅ Store video data
- ✅ Retrieve video data
- ✅ Manage cache lifecycle
- ✅ Provide cache statistics

**Key Methods**:
```swift
func cacheData(_ data: Data, for url: URL)
func cachedData(for url: URL, offset: Int64, length: Int) -> Data?
func isCached(url: URL) -> Bool
func clearCache()
```

### 2. VideoResourceLoaderDelegate
**Role**: Intercept and handle resource requests
- ✅ Implement AVAssetResourceLoaderDelegate
- ✅ Handle content information requests
- ✅ Handle data requests
- ✅ Coordinate cache and network

**Key Methods**:
```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   shouldWaitForLoadingOfRequestedResource: AVAssetResourceLoadingRequest) -> Bool
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   didCancel: AVAssetResourceLoadingRequest)
```

### 3. CachedVideoPlayerManager
**Role**: Create configured player items
- ✅ URL scheme conversion
- ✅ AVPlayerItem creation
- ✅ Delegate lifecycle management

**Key Methods**:
```swift
func createPlayerItem(with url: URL) -> AVPlayerItem
```

### 4. CachedVideoPlayer
**Role**: UI presentation
- ✅ Display video player
- ✅ Show cache status
- ✅ Playback controls
- ✅ Progress tracking

**Features**:
- Play/pause control
- Seek forward/backward
- Time display
- Cache indicator
- Download progress

## Request Flow Detail

```
AVPlayer Request
    │
    ├─ Content Info Request
    │  ├─ contentLength: Int64
    │  ├─ contentType: String (e.g., "video/mp4")
    │  └─ isByteRangeAccessSupported: Bool
    │
    └─ Data Request (multiple, in sequence)
       ├─ Request 1: offset=0, length=2MB
       ├─ Request 2: offset=2MB, length=2MB
       ├─ Request 3: offset=4MB, length=2MB
       └─ ... (continues based on playback)
```

## Cache Strategy

```
┌─────────────────────────────────────────┐
│          Cache Hierarchy                │
├─────────────────────────────────────────┤
│  Level 1: Memory Cache (NSCache)        │
│  • Size: ~100MB                         │
│  • Speed: Instant                       │
│  • Lifecycle: App session               │
│  • Best for: Recently played videos     │
├─────────────────────────────────────────┤
│  Level 2: Disk Cache (FileManager)      │
│  • Size: Limited by device storage      │
│  • Speed: Fast                          │
│  • Lifecycle: Persistent                │
│  • Best for: All cached videos          │
├─────────────────────────────────────────┤
│  Level 3: Network (URLSession)          │
│  • Size: N/A                            │
│  • Speed: Variable (depends on network) │
│  • Lifecycle: Per request               │
│  • Best for: First-time loading         │
└─────────────────────────────────────────┘
```

## Threading Model

```
┌──────────────────────────────────────────────┐
│              Main Thread                     │
│  • UI updates                                │
│  • AVPlayer operations                       │
│  • Resource loader delegate callbacks        │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│          URLSession Thread                   │
│  • Network downloads                         │
│  • Data reception                            │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│          Background Queue                    │
│  • File I/O operations (optional)            │
│  • Cache management tasks                    │
└──────────────────────────────────────────────┘
```

## Error Handling

```
Error Scenarios:
├─ Network Error
│  └─ Action: Finish loading request with error
│
├─ File System Error
│  └─ Action: Fall back to network download
│
├─ Invalid URL
│  └─ Action: Use original URL (no caching)
│
└─ Cancelled Request
   └─ Action: Remove from pending requests
```

## Performance Considerations

### Memory Usage
- Memory cache: ~100MB
- Each video player: ~50-100MB
- Recommendation: Limit concurrent players to 2-3

### Disk Usage
- Each video: Varies (typically 10-200MB)
- Recommendation: Implement cache size limit and LRU eviction

### Network Usage
- First load: Full video download
- Subsequent loads: Zero network usage
- Bandwidth savings: 100% for cached videos

## Extension Points

Want to enhance? Consider:

1. **Cache Eviction Policy**
   ```swift
   // Add to VideoCacheManager
   func evictOldestCacheIfNeeded(maxSize: Int64)
   ```

2. **Preloading**
   ```swift
   // Add to CachedVideoPlayerManager
   func preloadVideo(url: URL, priority: DownloadPriority)
   ```

3. **Analytics**
   ```swift
   // Add tracking
   func trackCacheHit(url: URL)
   func trackCacheMiss(url: URL)
   func getCacheHitRate() -> Double
   ```

4. **Background Downloads**
   ```swift
   // Use URLSession with background configuration
   let config = URLSessionConfiguration.background(withIdentifier: "com.app.videodownload")
   ```




