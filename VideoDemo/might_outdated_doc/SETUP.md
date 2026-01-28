# Setup Instructions

## Adding PINCache to the Project

This guide shows how to add PINCache dependency to enable hybrid memory + disk caching.

## Method 1: Swift Package Manager (Recommended)

1. **Open the project in Xcode**
   ```bash
   open VideoDemo.xcodeproj
   ```

2. **Add Package Dependency**
   - Go to **File → Add Package Dependencies...**
   - Or select the project in Navigator → Select target → **Package Dependencies** tab

3. **Add PINCache**
   - Enter URL: `https://github.com/pinterest/PINCache.git`
   - Dependency Rule: **Up to Next Major Version** → `3.0.0`
   - Click **Add Package**

4. **Link to Target**
   - Ensure **VideoDemo** target is checked
   - Click **Add Package**

5. **Verify Installation**
   - Build the project (Cmd+B)
   - You should see "📦 PINCache initialized: Memory=20MB, Disk=500MB" in console on first launch

## Method 2: CocoaPods

1. **Install CocoaPods** (if not already installed)
   ```bash
   sudo gem install cocoapods
   ```

2. **Create Podfile**
   ```bash
   cd VideoDemo
   cat > Podfile << 'EOF'
platform :ios, '17.0'
use_frameworks!

target 'VideoDemo' do
  pod 'PINCache', '~> 3.0'
end
EOF
   ```

3. **Install Dependencies**
   ```bash
   pod install
   ```

4. **Open Workspace**
   ```bash
   open VideoDemo.xcworkspace
   ```
   
   ⚠️ **Important**: Use `.xcworkspace` instead of `.xcodeproj` when using CocoaPods

5. **Build and Run**
   - Build the project (Cmd+B)
   - Run on simulator or device

## Troubleshooting

### Build Error: "No such module 'PINCache'"

**Solution 1**: Clean and rebuild
```bash
# In Xcode
Cmd+Shift+K  (Clean Build Folder)
Cmd+B        (Build)
```

**Solution 2**: Reset package cache (SPM)
```bash
# Close Xcode first
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf ~/Library/Developer/Xcode/DerivedData
# Reopen Xcode and rebuild
```

**Solution 3**: Reinstall pods (CocoaPods)
```bash
rm -rf Pods/ Podfile.lock
pod install
```

### Runtime Error: Cache not working

Check console for initialization message:
```
📦 PINCache initialized: Memory=20MB, Disk=500MB
```

If missing, verify:
1. PINCache is properly linked to target
2. No import errors in `PINCacheAssetDataManager.swift`
3. Build succeeded without warnings

### "Cannot find 'PINCache' in scope"

Ensure import statement is present:
```swift
import PINCache
```

And verify package is added to target:
- Project Navigator → Select Project
- Select VideoDemo target
- **General** tab → **Frameworks, Libraries, and Embedded Content**
- PINCache should be listed

## Verification

After successful setup, run the app and:

1. Select any video to play
2. Check console logs - you should see:
   ```
   📦 PINCache initialized: Memory=20MB, Disk=500MB
   📦 Video cache directory: /path/to/cache
   📦 VideoCacheManager initialized
   🎬 Created player item for: BigBuckBunny.mp4
   🌐 Request: bytes=0-1 for BigBuckBunny.mp4
   📋 Content info: 158008374 bytes
   💾 Saved 65536 bytes at offset 0
   ```

3. Switch videos and return - should see cache hits:
   ```
   ✅ Content info from cache
   ✅ Full data from cache: 65536 bytes
   ```

## Next Steps

- See `README.md` for full architecture documentation
- Adjust cache limits in `PINCacheAssetDataManager.swift`
- Test with sample videos
- Monitor cache size in app UI

## Need Help?

Common issues and solutions:

| Issue | Solution |
|-------|----------|
| Build errors | Clean build folder, reset package cache |
| Module not found | Verify package is added and linked to target |
| Cache not working | Check console logs for initialization |
| Performance issues | Reduce cache limits or increase polling interval |

For large video support (>100MB), see `README.md` section on FileHandleAssetDataManager.
