# Video Cache Demo with Progressive Caching

A complete iOS demo implementing **progressive video caching** using `AVAssetResourceLoaderDelegate` for smooth playback and offline viewing.

Based on: [ZhgChgLi's Article](https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/) and [ZPlayerCacher](https://github.com/ZhgChgLi/ZPlayerCacher)

## ✨ Features

- ✅ **Progressive Caching** - Videos cache chunk-by-chunk as they download
- ✅ **Resume Support** - Continue downloads from where you left off
- ✅ **Instant Playback** - Play cached portions immediately
- ✅ **Partial Cache Support** - Play and seek within cached ranges
- ✅ **Visual Progress** - See cache percentage for each video
- ✅ **Thread-Safe** - Handles concurrent downloads properly
- ✅ **Memory Efficient** - Recent chunks in memory, full data on disk
- ✅ **Offline Playback** - Cached videos work without internet

## 📁 Project Structure

```
VideoDemo/
├── VideoCacheManager.swift              # Cache management + metadata
├── VideoResourceLoaderDelegate.swift    # Progressive download handler
├── CachedVideoPlayerManager.swift       # Player item creation
├── CachedVideoPlayer.swift              # SwiftUI video player
├── ContentView.swift                    # Demo UI with cache indicators
└── VideoDemoApp.swift                   # App entry point
```

## 🚀 Quick Start

### 1. Configure Network Security

Since the demo uses HTTP test videos, you need to allow HTTP connections:

1. Open project in Xcode
2. Select **VideoDemo** project → **VideoDemo** target → **Info** tab
3. Add key: `App Transport Security Settings` (Dictionary)
4. Inside it, add: `Allow Arbitrary Loads` (Boolean) = **YES**

### 2. Build and Run

```bash
cd VideoDemo
open VideoDemo.xcodeproj
# Press Cmd+R to build and run
```

### 3. Test Progressive Caching

1. **Play a video** - Tap "Big Buck Bunny"
   - Watch percentage increase: 5% → 10% → 15%...
   - Video plays while downloading

2. **Stop at 30%** - Tap "Elephant Dream"
   - Big Buck Bunny shows: 🟠 30%
   - Progress is saved!

3. **Resume** - Tap "Big Buck Bunny" again
   - Plays immediately from 0-30% (cached)
   - Downloads continue from 30%
   - Console shows HTTP 206 (Partial Content)

## 🎯 How It Works

### Custom URL Scheme

```
Original: http://example.com/video.mp4
Custom:   cachevideo://example.com/video.mp4
```

The custom scheme triggers `AVAssetResourceLoaderDelegate` to intercept all data requests.

### Progressive Download Flow

```
1. Chunk arrives (256KB)
   ↓
2. Save to disk immediately
   ↓
3. Keep in memory (recent 20 chunks)
   ↓
4. Update metadata (ranges cached)
   ↓
5. Respond to AVPlayer requests
```

### Cache Serving Strategy

```
Player requests data at offset X:
  ├─ Check recent chunks (memory) → Instant
  ├─ Check disk cache → Fast
  └─ Download from network → Progressive
```

## 📊 UI Cache Indicators

- **☁️ Not Cached** - No data downloaded
- **🟠 30%** - Partially cached (shows exact percentage)
- **✅ 100%** - Fully cached and ready for offline playback

Updates automatically every 2 seconds.

## 🧪 Testing

### Test Scenario 1: Progressive Caching

```bash
1. Clear cache
2. Play video → See: 1% → 5% → 10%...
3. Video plays while downloading
4. Check console: "💾 Received chunk: ... (12.5%)"
```

### Test Scenario 2: Resume from Partial Cache

```bash
1. Download to 30%
2. Switch to another video
3. Return to first video
4. Console shows:
   - "📍 Resuming download from byte X"
   - "📡 Received response: status=206"
5. Plays 0-30% instantly, continues from 30%
```

### Test Scenario 3: Offline Playback

```bash
1. Download video to 100%
2. Stop app
3. Disable network (Airplane mode)
4. Restart app
5. Play cached video → Works perfectly!
```

## 🏗️ Architecture

### VideoCacheManager
- Disk cache management (persistent)
- Metadata tracking (ranges, size, completion)
- Thread-safe dictionary access
- Cache size calculation

### VideoResourceLoaderDelegate
- Implements `AVAssetResourceLoaderDelegate`
- Handles `URLSessionDataDelegate` for progressive data
- Recent chunks buffer (~5MB in memory)
- Serves data from cache or network
- HTTP Range request support

### Key Components

```swift
// Metadata structure
struct CacheMetadata {
    var contentLength: Int64?
    var cachedRanges: [CachedRange]
    var isFullyCached: Bool
}

// Simple chunk buffer (no complex trimming!)
private var recentChunks: [(offset: Int64, data: Data)]
```

## 🐛 Issues Encountered & Solutions

### Issue 1: Info.plist Conflict
**Problem**: "Multiple commands produce Info.plist"  
**Cause**: Manual Info.plist conflicted with Xcode auto-generation  
**Solution**: Delete manual Info.plist, configure via Xcode UI

### Issue 2: Buffer Offset Crash
**Problem**: `EXC_BREAKPOINT` when accessing buffer after trimming  
**Cause**: Complex buffer trimming with offset tracking had race conditions  
**Solution**: Simplified to array of chunks with FIFO removal

### Issue 3: Thread Safety in Metadata
**Problem**: Dictionary corruption with concurrent video downloads  
**Cause**: Multiple delegates writing to shared dictionary without locks  
**Solution**: Added `NSLock` for all metadata cache access

### Issue 4: Cached Video Won't Play After Restart
**Problem**: "Cannot Open" error for fully cached videos  
**Cause**: Tried playing raw cached file directly  
**Solution**: Always use resource loader delegate, even for cached videos

### Issue 5: Video Won't Play from Partial Cache
**Problem**: Waits for full download even when 30% is cached  
**Cause**: `cachedData()` returned nil if full range not available  
**Solution**: Serve partial data - return what's available, not all-or-nothing

### Issue 6: Missing Percentage on Resume
**Problem**: No percentage shown when resuming downloads  
**Cause**: `expectedContentLength` not parsed from HTTP 206 response  
**Solution**: Parse `Content-Range` header to extract total size

## 💡 Key Learnings

1. **Simple is Better** - Complex buffer management caused crashes. Simple chunk array worked perfectly.

2. **Thread Safety is Critical** - Multiple downloads happening simultaneously require proper synchronization.

3. **Serve Partial Data** - Don't wait for complete ranges. Serve what's available for smooth playback.

4. **Always Use Delegate** - Even for fully cached videos, use the resource loader for consistent handling.

5. **HTTP 206 is Your Friend** - Proper resume support requires understanding Content-Range headers.

## 📝 Technical Details

### Memory Management

- **Recent Chunks**: Last 20 chunks (~5MB) in RAM for instant access
- **Disk Cache**: All downloaded data persisted
- **Strategy**: Hot data in memory, complete data on disk

### Thread Safety

- **Metadata**: Protected by `NSLock`
- **Recent Chunks**: Protected by `NSLock`  
- **File I/O**: FileHandle operations are thread-safe

### Cache Strategy

```
Request at offset X:
  1. Check recentChunks (memory) - O(n), n≤20
  2. Check disk cache - O(1) file seek
  3. Download if missing - Progressive
```

## 🚧 Limitations

1. **HTTP Only** - Demo uses HTTP. Use HTTPS in production.
2. **No Cache Size Limit** - Implement LRU eviction for production.
3. **No DRM Support** - Doesn't work with FairPlay content.
4. **MP4 Only** - Best with progressive MP4 files.
5. **No HLS Support** - Designed for single-file videos.

## 🔮 Future Enhancements

- [ ] Cache size limit with LRU eviction
- [ ] Background download support
- [ ] Download queue management  
- [ ] HLS streaming support
- [ ] Download priority levels
- [ ] Analytics (cache hit rate, bandwidth saved)

## 📚 Documentation

- **README.md** - This file (overview & quick start)
- **ARCHITECTURE.md** - Detailed system architecture
- **IMPLEMENTATION_GUIDE.md** - Step-by-step implementation
- **NETWORK_SETUP.md** - Network configuration guide
- **TROUBLESHOOTING.md** - Common issues and solutions

## 🙏 Credits

- Original concept: [ZhgChgLi's Article](https://en.zhgchg.li/posts/zrealm-dev/avplayer-local-cache-implementation-master-avassetresourceloaderdelegate-for-smooth-playback-6ce488898003/)
- Reference implementation: [ZPlayerCacher](https://github.com/ZhgChgLi/ZPlayerCacher)
- Sample videos: [Google's test video repository](http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/)

## 📄 License

This is a demo project for educational purposes.

## ✅ Final Status

**All features working:**
- ✅ Progressive caching (chunk-by-chunk)
- ✅ Resume from partial cache
- ✅ Instant playback from cache
- ✅ Visual progress indicators
- ✅ Thread-safe concurrent downloads
- ✅ Offline playback support
- ✅ HTTP Range request support
- ✅ Metadata persistence

**Ready for production with:**
- Cache size management
- HTTPS enforcement
- Error analytics
- Background downloads (optional)
