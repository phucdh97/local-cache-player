# Troubleshooting & Best Practices

## Common Issues

### 1. Video Not Playing

#### Symptom
Video player shows loading indicator indefinitely or displays black screen.

#### Possible Causes & Solutions

**A. Network Security Configuration**
```
Error: "App Transport Security has blocked a cleartext HTTP resource load"
```

**Solution**: Update `Info.plist`
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
```

For production, use specific exceptions:
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSExceptionDomains</key>
    <dict>
        <key>example.com</key>
        <dict>
            <key>NSIncludesSubdomains</key>
            <true/>
            <key>NSTemporaryExceptionAllowsInsecureHTTPLoads</key>
            <true/>
        </dict>
    </dict>
</dict>
```

**B. URL Scheme Not Recognized**

Check if custom URL is created correctly:
```swift
// Debug in CachedVideoPlayerManager
print("Original URL: \(url)")
print("Custom URL: \(customURL)")
// Should show: cachevideo://...
```

**C. Resource Loader Not Called**

Ensure delegate is set before player starts:
```swift
asset.resourceLoader.setDelegate(delegate, queue: DispatchQueue.main)
let item = AVPlayerItem(asset: asset)
```

**D. Video Format Not Supported**

Check video codec:
```swift
// Supported: H.264, HEVC
// Unsupported: VP8, VP9 (without special handling)
```

### 2. Cache Not Working

#### Symptom
Videos always download, never serve from cache.

#### Possible Causes & Solutions

**A. Cache Check Failing**

Add debug logs:
```swift
func isCached(url: URL) -> Bool {
    let filePath = cacheFilePath(for: url)
    let exists = fileManager.fileExists(atPath: filePath.path)
    print("🔍 Cache check for \(url.lastPathComponent): \(exists)")
    print("📁 Path: \(filePath.path)")
    return exists
}
```

**B. File Permissions**

Check cache directory access:
```swift
let cacheDir = VideoCacheManager.shared.cacheDirectory
print("Cache dir: \(cacheDir)")
print("Exists: \(FileManager.default.fileExists(atPath: cacheDir.path))")
print("Writable: \(FileManager.default.isWritableFile(atPath: cacheDir.path))")
```

**C. Incomplete Downloads**

Verify file size:
```swift
if let size = getCachedFileSize(for: url) {
    print("Cached size: \(size) bytes")
}
```

### 3. Memory Issues

#### Symptom
App crashes or becomes slow after playing multiple videos.

#### Solutions

**A. Limit Memory Cache**
```swift
// In VideoCacheManager init
memoryCache.countLimit = 20 // Reduce from 50
memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB instead of 100 MB
```

**B. Clear Cache Regularly**
```swift
// Add to VideoDemoApp.swift
.onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
    VideoCacheManager.shared.memoryCache.removeAllObjects()
}
```

**C. Limit Concurrent Players**
```swift
// Only keep one active player at a time
@State private var currentPlayer: AVPlayer?

// When switching videos
currentPlayer?.pause()
currentPlayer = nil
currentPlayer = newPlayer
```

### 4. Playback Issues

#### Symptom
Video stutters, buffers, or plays choppy.

#### Solutions

**A. Buffer Size**
```swift
// Add to AVPlayerItem
playerItem.preferredForwardBufferDuration = 5.0 // 5 seconds
```

**B. Network Conditions**
```swift
// Add network quality check
import Network

let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { path in
    if path.status == .satisfied {
        print("Network available")
    }
}
```

**C. Read Performance**
```swift
// Use FileHandle for better performance
let fileHandle = try FileHandle(forReadingFrom: filePath)
defer { try? fileHandle.close() }
try fileHandle.seek(toOffset: UInt64(offset))
let data = fileHandle.readData(ofLength: length)
```

## Best Practices

### 1. Error Handling

Always handle errors gracefully:

```swift
// In VideoResourceLoaderDelegate
private func finishLoadingWithError(_ error: Error) {
    print("❌ Loading error: \(error.localizedDescription)")
    
    DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        
        for request in self.loadingRequests {
            request.finishLoading(with: error)
        }
        self.loadingRequests.removeAll()
    }
}
```

### 2. Resource Cleanup

Ensure proper cleanup to prevent memory leaks:

```swift
deinit {
    // Remove observers
    if let observer = timeObserver {
        player?.removeTimeObserver(observer)
    }
    statusObserver?.invalidate()
    
    // Cancel tasks
    task?.cancel()
    
    // Clear delegates
    playerManager.clearResourceLoaders()
    
    print("♻️ Cleaned up resources")
}
```

### 3. Thread Safety

Keep UI updates on main thread:

```swift
DispatchQueue.main.async {
    self.isDownloading = false
    self.isCached = true
}
```

### 4. Cache Management

Implement smart cache management:

```swift
// Auto-clear old cache
func clearOldCache(olderThan days: Int) {
    let calendar = Calendar.current
    let cutoffDate = calendar.date(byAdding: .day, value: -days, to: Date())!
    
    let contents = try? fileManager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey]
    )
    
    contents?.forEach { url in
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           date < cutoffDate {
            try? fileManager.removeItem(at: url)
        }
    }
}
```

### 5. Network Optimization

Use efficient network handling:

```swift
// Add timeout
var request = URLRequest(url: originalURL)
request.timeoutInterval = 30
request.cachePolicy = .reloadIgnoringLocalCacheData

// Add headers if needed
request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
```

### 6. Progress Tracking

Implement download progress:

```swift
// Use URLSessionDownloadDelegate
extension VideoResourceLoaderDelegate: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, 
                   downloadTask: URLSessionDownloadTask,
                   didWriteData bytesWritten: Int64,
                   totalBytesWritten: Int64,
                   totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        print("📊 Download progress: \(Int(progress * 100))%")
    }
}
```

## Performance Optimization

### 1. Lazy Loading

Don't load all videos at once:

```swift
// In ContentView
LazyVStack {
    ForEach(videoURLs, id: \.url) { video in
        VideoRowView(video: video)
    }
}
```

### 2. Image Thumbnails

Cache video thumbnails separately:

```swift
func generateThumbnail(for url: URL) async -> UIImage? {
    let asset = AVAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    
    do {
        let cgImage = try await generator.image(at: .zero).image
        return UIImage(cgImage: cgImage)
    } catch {
        return nil
    }
}
```

### 3. Preloading Strategy

Preload next video while current plays:

```swift
func preloadNextVideo() {
    guard let nextURL = getNextVideoURL() else { return }
    
    Task {
        let item = playerManager.createPlayerItem(with: nextURL)
        // Item creation triggers download if not cached
    }
}
```

## Testing Checklist

### Functional Tests
- [ ] First time play from network
- [ ] Second time play from cache
- [ ] Seek during download
- [ ] Seek with cached video
- [ ] Play/pause controls
- [ ] Cache status updates
- [ ] Clear cache works
- [ ] Multiple videos can cache
- [ ] App background/foreground
- [ ] App restart (cache persists)

### Performance Tests
- [ ] Memory usage under 200MB
- [ ] Smooth playback (60fps)
- [ ] Quick cache retrieval (<100ms)
- [ ] Network usage optimized
- [ ] Battery usage reasonable

### Edge Cases
- [ ] No network connection
- [ ] Slow network (3G)
- [ ] Interrupted download
- [ ] Full disk space
- [ ] Invalid URL
- [ ] Corrupted cache file
- [ ] Simultaneous requests
- [ ] Very large videos (>500MB)

## Debug Tips

### 1. Enable Verbose Logging

Add detailed logs:

```swift
// Add to VideoCacheManager
private var isDebugEnabled = true

func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    if isDebugEnabled {
        let filename = (file as NSString).lastPathComponent
        print("[\(filename):\(line)] \(function) - \(message)")
    }
}
```

### 2. Network Debugging

Use Charles Proxy or Proxyman to inspect network traffic:
- Monitor download requests
- Check response headers
- Verify data integrity

### 3. File System Inspection

Check cache files:

```swift
// Print cache contents
func printCacheContents() {
    let contents = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])
    
    print("📂 Cache Contents:")
    contents?.forEach { url in
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        print("  - \(url.lastPathComponent): \(size) bytes")
    }
}
```

### 4. Memory Profiling

Use Instruments:
1. Open Xcode → Product → Profile
2. Select "Allocations" or "Leaks"
3. Play multiple videos
4. Check for memory growth

### 5. Player Status Monitoring

Add detailed status logging:

```swift
playerItem.observe(\.status) { item, _ in
    switch item.status {
    case .unknown:
        print("🤔 Player status: Unknown")
    case .readyToPlay:
        print("✅ Player status: Ready to play")
    case .failed:
        print("❌ Player status: Failed - \(item.error?.localizedDescription ?? "unknown")")
    @unknown default:
        print("⚠️ Player status: Unknown case")
    }
}
```

## Production Considerations

### 1. Analytics

Track important metrics:

```swift
struct CacheAnalytics {
    static func trackCacheHit(url: URL) {
        // Your analytics service
        print("📊 Cache Hit: \(url)")
    }
    
    static func trackCacheMiss(url: URL) {
        // Your analytics service
        print("📊 Cache Miss: \(url)")
    }
    
    static func trackDownloadTime(url: URL, duration: TimeInterval) {
        // Your analytics service
        print("📊 Download Time: \(duration)s for \(url)")
    }
}
```

### 2. Security

For production apps:
- Use HTTPS only
- Validate cache integrity
- Encrypt sensitive videos
- Implement access controls

### 3. User Settings

Give users control:

```swift
struct CacheSettings {
    var maxCacheSize: Int64 = 1_000_000_000 // 1 GB
    var autoDownloadOnWiFiOnly: Bool = true
    var cacheExpiration: TimeInterval = 7 * 24 * 60 * 60 // 7 days
}
```

### 4. Monitoring

Monitor app health:
- Cache hit rate
- Average download time
- Error rates
- Storage usage
- User engagement

## FAQ

**Q: Can I use this for live streaming?**
A: No, this is designed for VOD (Video on Demand). Live streams require different handling.

**Q: Does this work with DRM content?**
A: No, DRM content requires FairPlay Streaming and different approach.

**Q: How much storage can videos use?**
A: Currently unlimited. Implement cache size limits for production.

**Q: Can videos be downloaded in background?**
A: Not currently. Modify to use background URLSession for this feature.

**Q: What video formats are supported?**
A: Any format supported by AVPlayer (MP4 with H.264/HEVC recommended).

**Q: Can I seek to any position during download?**
A: Only to downloaded portions. Future improvements could support range requests.

## Getting Help

If you encounter issues:

1. Check this troubleshooting guide
2. Review the implementation guide
3. Check Apple's AVFoundation documentation
4. Search Stack Overflow for similar issues
5. Review the original article

## Contributing

Ideas for improvements:
- Better error handling
- Download queue management
- Subtitle/audio track caching
- Adaptive bitrate support
- Cache encryption
- Background downloads

Feel free to extend and customize for your needs!





