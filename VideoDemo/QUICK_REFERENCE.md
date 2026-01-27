# Quick Reference Guide

## 🚀 Quick Start

1. **Add PINCache** (Choose one method):
   ```bash
   # Method 1: SPM (in Xcode)
   File → Add Package Dependencies → https://github.com/pinterest/PINCache.git
   
   # Method 2: CocoaPods
   pod 'PINCache', '~> 3.0'
   pod install
   ```

2. **Build & Run**:
   ```bash
   Cmd+Shift+K  # Clean
   Cmd+B        # Build
   Cmd+R        # Run
   ```

3. **Verify** - Check console for:
   ```
   📦 PINCache initialized: Memory=20MB, Disk=500MB
   ```

## 📁 New File Structure

```
NEW FILES (from reference):
✅ AssetData.swift                    - Data models
✅ AssetDataManager.swift             - Cache protocol
✅ PINCacheAssetDataManager.swift     - PINCache implementation
✅ ResourceLoaderRequest.swift        - Per-request handler
✅ ResourceLoader.swift               - Main coordinator
✅ CachingAVURLAsset.swift            - Asset wrapper

REFACTORED FILES:
🔄 VideoCacheManager.swift            - Simplified to UI queries only
🔄 CachedVideoPlayerManager.swift     - Uses CachingAVURLAsset
🔄 CachedVideoPlayer.swift            - Synchronous cache checks
🔄 ContentView.swift                  - Simple polling timer

DELETED FILES:
❌ VideoResourceLoaderDelegate.swift  - Replaced by ResourceLoader + ResourceLoaderRequest
```

## 🎯 Key Architecture Changes

| Component | Before | After |
|-----------|--------|-------|
| **Request Tracking** | Array + single task | Dictionary + task per request |
| **Queue** | Main queue | Dedicated serial queue |
| **Cache** | Actor + FileHandle | PINCache (protocol-based) |
| **Memory Cache** | None | 20MB with LRU |
| **Disk Cache** | Unlimited | 500MB with LRU |
| **UI Updates** | Complex async | Simple 2.5s polling |

## 🔑 Critical Patterns

### 1. Dictionary Tracking
```swift
// Each AVPlayer request gets own network operation
private var requests: [AVAssetResourceLoadingRequest: ResourceLoaderRequest] = [:]
```

### 2. Dedicated Queue
```swift
// NOT main queue - dedicated serial queue
let loaderQueue = DispatchQueue(label: "com.videodemo.resourceLoader.queue")
asset.resourceLoader.setDelegate(resourceLoader, queue: loaderQueue)
```

### 3. Stream + Cache
```swift
// Receive data chunk
self.loaderQueue.async {
    self.delegate?.dataRequestDidReceive(self, data)  // → AVPlayer (immediate)
    self.downloadedData.append(data)                   // → Cache (on complete)
}
```

### 4. Cache-First
```swift
// Check cache first
if let assetData = assetDataManager.retrieveAssetData() {
    // Serve from cache if available
    loadingRequest.dataRequest?.respond(with: cachedData)
    loadingRequest.finishLoading()
    return true
}
// Start network request if cache miss
```

## 📊 Console Log Guide

### Successful Flow
```
📦 PINCache initialized: Memory=20MB, Disk=500MB
📦 VideoCacheManager initialized
🎬 Created player item for: BigBuckBunny.mp4
🌐 Request: bytes=0-1 for BigBuckBunny.mp4
📋 Content info: 158008374 bytes
🌐 Request: bytes=0-65536 for BigBuckBunny.mp4
💾 Saved 65536 bytes at offset 0
✅ Full data from cache: 65536 bytes
```

### Cache Hit
```
✅ Content info from cache
✅ Full data from cache: 131072 bytes
```

### Partial Cache
```
⚡️ Partial data from cache: 65536 bytes, continuing to network...
```

## 🛠️ Configuration

### Adjust Cache Limits
`PINCacheAssetDataManager.swift`:
```swift
cache.memoryCache.costLimit = 20 * 1024 * 1024  // Memory: 20MB
cache.diskCache.byteLimit = 500 * 1024 * 1024   // Disk: 500MB
```

### Adjust UI Refresh Rate
`ContentView.swift`:
```swift
try? await Task.sleep(for: .seconds(2.5))  // Polling interval
```

## 🧪 Test Checklist

- [ ] First download shows progressive caching
- [ ] Percentage updates every 2.5 seconds
- [ ] Cache hit on second launch shows instant load
- [ ] Partial cache resumes download
- [ ] Seeking works during download
- [ ] Cancel works when switching videos
- [ ] Resume works when returning to video
- [ ] Clear cache resets all percentages

## ⚠️ Common Issues

| Issue | Solution |
|-------|----------|
| "No such module 'PINCache'" | Add PINCache via SPM or CocoaPods |
| Build errors | Clean build folder (Cmd+Shift+K) |
| No cache logs | Check PINCache is linked to target |
| Main thread lag | Verify using loaderQueue, not main |
| Seek not working | Check dictionary tracking is active |

## 📚 File Purposes

| File | Purpose |
|------|---------|
| `AssetData.swift` | Data models (NSCoding for PINCache) |
| `AssetDataManager.swift` | Protocol for cache implementations |
| `PINCacheAssetDataManager.swift` | PINCache concrete implementation |
| `ResourceLoaderRequest.swift` | Handles ONE loading request |
| `ResourceLoader.swift` | Coordinates ALL loading requests |
| `CachingAVURLAsset.swift` | Custom scheme + auto-setup |
| `VideoCacheManager.swift` | UI-facing cache queries |
| `CachedVideoPlayerManager.swift` | Creates cached player items |
| `CachedVideoPlayer.swift` | SwiftUI player view |
| `ContentView.swift` | Main UI with video list |

## 🎓 Learning Resources

- **Blog**: https://en.zhgchg.li/posts/.../avplayer-local-cache-implementation...
- **Reference**: `resourceLoaderDemo-main/` folder
- **Plan**: `.cursor/plans/progressive_cache_refactor_*.plan.md`
- **Detailed Flow**: `resourceLoaderDemo-main/DETAILED_FLOW_ANALYSIS.md`

## 🔮 Future Extensions

### Large Video Support (>100MB)
Create `FileHandleAssetDataManager`:
```swift
class FileHandleAssetDataManager: AssetDataManager {
    // Memory: Keep only recent chunks (~20MB)
    // Disk: Use FileHandle seek/write
    // Protocol: Same interface, no changes to ResourceLoader
}
```

Then swap:
```swift
let assetDataManager = FileHandleAssetDataManager(cacheKey: cacheKey)
```

## ✅ Success Indicators

When everything works:
- ✅ Console shows PINCache initialization
- ✅ Videos cache progressively (percentage updates)
- ✅ Second launch loads from cache instantly
- ✅ Seeking works before full download
- ✅ Cache size shown correctly in UI
- ✅ LRU eviction happens at limits
- ✅ No main thread blocking

## 🆘 Need Help?

1. Check `SETUP.md` for detailed installation steps
2. Check `README.md` for architecture details
3. Check `IMPLEMENTATION_SUMMARY.md` for complete changes
4. Check console logs for error messages
5. Check resourceLoaderDemo reference implementation

---

**Status**: ✅ All implementation complete, ready for testing after PINCache installation
