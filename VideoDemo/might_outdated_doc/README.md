# VideoDemo - Progressive Video Caching

A SwiftUI video player app with progressive caching support, following the ZPlayerCacher architecture.

## Architecture

This project implements progressive video caching based on [ZPlayerCacher](https://github.com/ZhgChgLi/ZPlayerCacher) by Zhong Cheng Li.

### Key Components

1. **ResourceLoader** - Main coordinator implementing `AVAssetResourceLoaderDelegate`
   - Uses dictionary-based request tracking
   - Dedicated serial queue for thread safety
   - Cache-first strategy

2. **ResourceLoaderRequest** - Individual request handler
   - One request per AVAssetResourceLoadingRequest
   - Streams data to AVPlayer while accumulating for cache
   - Uses URLSession for network operations

3. **AssetDataManager Protocol** - Cache abstraction
   - `PINCacheAssetDataManager` - Default implementation using PINCache
   - Easy to swap implementations (e.g., FileHandle for large videos)

4. **CachingAVURLAsset** - Custom AVURLAsset wrapper
   - Automatically sets up resource loader with custom scheme
   - Handles scheme conversion (http → cachevideo)

5. **VideoCacheManager** - UI-facing cache queries
   - Simple synchronous API for UI polling
   - No complex async state management

## Setup Instructions

### Prerequisites

- Xcode 15.0 or later
- iOS 17.0 or later

### Adding PINCache Dependency

This project requires PINCache for hybrid memory + disk caching with LRU eviction.

#### Option 1: Swift Package Manager (Recommended)

1. Open the project in Xcode
2. Go to **File → Add Package Dependencies...**
3. Enter the URL: `https://github.com/pinterest/PINCache.git`
4. Select version: `3.0.0` or later
5. Click **Add Package**

#### Option 2: CocoaPods

1. Create a `Podfile` in the project root:

```ruby
platform :ios, '17.0'
use_frameworks!

target 'VideoDemo' do
  pod 'PINCache', '~> 3.0'
end
```

2. Run `pod install`
3. Open `VideoDemo.xcworkspace` instead of `.xcodeproj`

## Configuration

### Cache Limits

Configured in `PINCacheAssetDataManager.swift`:

- **Memory Cache**: 20MB (fast access to recent videos)
- **Disk Cache**: 500MB (persistent storage with LRU eviction)

To adjust:

```swift
static let Cache: PINCache = {
    let cache = PINCache(name: "ResourceLoader")
    cache.memoryCache.costLimit = 20 * 1024 * 1024  // Change here
    cache.diskCache.byteLimit = 500 * 1024 * 1024   // Change here
    return cache
}()
```

### UI Refresh Rate

Cache percentage updates poll every 2.5 seconds (configured in `ContentView.swift`):

```swift
try? await Task.sleep(for: .seconds(2.5))  // Adjust here
```

## Features

- ✅ Progressive video caching (watch while downloading)
- ✅ Resume downloads from where they left off
- ✅ Switch videos without blocking (cancel previous, start new)
- ✅ Seek to cached portions before full download
- ✅ LRU eviction when cache limits reached
- ✅ Cache status indicators (cached, partial, not cached)
- ✅ Simple UI-driven percentage polling (no complex callbacks)

## Testing

Sample videos from Google's test video bucket are pre-configured:

- Big Buck Bunny
- Elephant Dream
- Sintel
- Tears of Steel
- For Bigger Blazes

### Test Scenarios

1. **First download**: Select a video, observe progressive caching
2. **Resume**: Switch to another video, then back - should resume from cache
3. **Seek**: Seek during download to test cached ranges
4. **Cancel**: Switch videos to test download cancellation
5. **Cache limit**: Download multiple videos to test LRU eviction

## Architecture Diagram

```
ContentView (UI)
    ↓ (poll every 2.5s)
VideoCacheManager
    ↓ (query)
PINCacheAssetDataManager (AssetDataManager protocol)
    ↓ (read/write)
PINCache (20MB mem + 500MB disk, LRU)

CachedVideoPlayer
    ↓ (create player)
CachedVideoPlayerManager
    ↓ (create asset)
CachingAVURLAsset
    ↓ (sets delegate)
ResourceLoader (AVAssetResourceLoaderDelegate)
    ↓ (dictionary tracking)
ResourceLoaderRequest (URLSessionDelegate)
    ↓ (stream + cache)
[AVPlayer receives data] + [PINCache stores data]
```

## Key Patterns

### 1. Dictionary-Based Request Tracking

```swift
private var requests: [AVAssetResourceLoadingRequest: ResourceLoaderRequest] = [:]
```

Each AVPlayer request gets its own network operation, enabling:
- Multiple concurrent range requests (seeking)
- Individual cancellation
- Proper cleanup

### 2. Dedicated Serial Queue

```swift
let loaderQueue = DispatchQueue(label: "com.videodemo.resourceLoader.queue")
```

**NOT** main queue - ensures thread-safe coordination between:
- AVFoundation callbacks
- URLSession callbacks
- Cache operations

### 3. Streaming + Caching

```swift
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.loaderQueue.async {
        self.delegate?.dataRequestDidReceive(self, data)  // Stream to AVPlayer
        self.downloadedData.append(data)                   // Accumulate for cache
    }
}
```

### 4. Cache-First Strategy

Check cache → Serve from cache if available → Start network request if needed

## Extending for Large Videos

For videos >100MB, PINCache may cause OOM. Create `FileHandleAssetDataManager`:

```swift
class FileHandleAssetDataManager: NSObject, AssetDataManager {
    // Use FileHandle seek/write for disk
    // Keep only recent chunks (~20MB) in memory
    // Same protocol interface - no changes to ResourceLoader!
}
```

Then swap implementations:

```swift
let assetDataManager = FileHandleAssetDataManager(cacheKey: self.cacheKey)
```

## Troubleshooting

### Videos not caching

1. Check console logs for "📦 PINCache initialized"
2. Verify PINCache is properly linked
3. Check network permissions

### Build errors

1. Ensure PINCache is added via SPM or CocoaPods
2. Clean build folder (Cmd+Shift+K)
3. Delete DerivedData

### Performance issues

1. Reduce cache limits if memory constrained
2. Increase UI polling interval for lower CPU usage
3. Consider FileHandleAssetDataManager for large videos

## References

- [ZPlayerCacher GitHub](https://github.com/ZhgChgLi/ZPlayerCacher)
- [Blog Post (English)](https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/)
- [PINCache](https://github.com/pinterest/PINCache)
- [AVAssetResourceLoader Documentation](https://developer.apple.com/documentation/avfoundation/avassetresourceloader)

## License

This project is for demonstration purposes. See ZPlayerCacher for original implementation license.
