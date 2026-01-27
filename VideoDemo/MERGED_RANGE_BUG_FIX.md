# Critical Bug Fix - Merged Range Retrieval

## Problem Identified

When returning to Video 1 after caching data, the system was **not serving cached data properly**, forcing unnecessary re-downloads even though the data was cached. This bug was **masked by network availability** but became visible when testing offline.

## Root Cause

The bug occurred in `PINCacheAssetDataManager.retrieveDataInRange()` when handling **merged ranges**.

### How Range Merging Works

1. **Initial state**: Cache range `0-13194` with chunk `chunk_0` (13194 bytes)
2. **Add data**: Cache range `13194-65537` with chunk `chunk_13194` (52343 bytes)
3. **After merge**: Range metadata becomes `0-65537` (merged)
4. **Storage**: Chunks remain separate: `chunk_0` (13194 bytes) + `chunk_13194` (52343 bytes)

### The Bug

**Old code** tried to load the entire merged range from a single chunk:

```swift
// Load chunk for this range (BUG: assumes single chunk)
let chunkKey = "\(cacheKey)_chunk_\(range.offset)"  // Only loads chunk_0
guard let chunkData = PINCacheAssetDataManager.Cache.object(forKey: chunkKey) as? Data else {
    return nil
}

// Calculate offset in chunk
let startInChunk = max(0, Int(currentOffset - range.offset))
let endInChunk = min(chunkData.count, Int(endOffset - range.offset))
// BUG: chunkData.count = 13194, but range says it should be 65537!
```

**When requesting offset 65536:**
- Range metadata: `0-65537` ✅ (merged)
- Loaded chunk: `chunk_0` with only 13194 bytes ❌
- Request offset: 65536
- Calculation: `startInChunk = max(0, 65536 - 0) = 65536`
- Calculation: `endInChunk = min(13194, huge_number - 0) = 13194`
- Check: `if 65536 < 13194` → **FALSE** ❌
- Result: No data returned, even though bytes 65536-65537 are in `chunk_13194`!

## The Fix

**New approach**: Scan all actual chunks within merged ranges and iterate through them individually:

```swift
// Get all chunk metadata by scanning actual stored chunks
let allChunkKeys = getAllChunkKeys(for: assetData.cachedRanges)

// Sort chunks by their offset
let sortedChunks = allChunkKeys.sorted { $0.offset < $1.offset }

for chunkInfo in sortedChunks {
    // Load individual chunk
    let chunkKey = "\(cacheKey)_chunk_\(chunkInfo.offset)"
    guard let chunkData = PINCacheAssetDataManager.Cache.object(forKey: chunkKey) as? Data else {
        continue
    }
    
    // Extract relevant portion from THIS chunk
    let startInChunk = max(0, Int(currentOffset - chunkInfo.offset))
    let endInChunk = min(chunkData.count, Int(endOffset - chunkInfo.offset))
    
    // Append to result
    if startInChunk < endInChunk {
        result.append(chunkData.subdata(in: startInChunk..<endInChunk))
        currentOffset = chunkInfo.offset + Int64(endInChunk)
    }
}
```

### New Helper Method

```swift
private func getAllChunkKeys(for ranges: [CachedRange]) -> [(offset: Int64, length: Int)] {
    var chunks: [(offset: Int64, length: Int)] = []
    
    for range in ranges {
        var searchOffset = range.offset
        let rangeEnd = range.offset + range.length
        
        // Walk through the range and find all actual chunks
        while searchOffset < rangeEnd {
            let chunkKey = "\(cacheKey)_chunk_\(searchOffset)"
            if let chunkData = PINCacheAssetDataManager.Cache.object(forKey: chunkKey) as? Data {
                chunks.append((offset: searchOffset, length: chunkData.count))
                searchOffset += Int64(chunkData.count)
            } else {
                break  // No more chunks in this range
            }
        }
    }
    
    return chunks
}
```

## What Was Wrong - Detailed Example

### Cached State
- Range metadata: `0-65537` (after merging `0-13194` + `13194-65537`)
- Chunk storage:
  - `chunk_0`: 13194 bytes (offset 0)
  - `chunk_13194`: 52343 bytes (offset 13194)

### Request: bytes 65536-158008374

**Old Code Path:**
1. Find range `0-65537` that contains request start ✅
2. Load `chunk_0` (13194 bytes) ❌ **WRONG CHUNK**
3. Calculate: `startInChunk = 65536`, `endInChunk = 13194`
4. Check: `65536 < 13194` → FALSE
5. Return: ❌ No data available
6. Result: Go to network (wasted bandwidth)

**New Code Path:**
1. Scan range `0-65537` for all chunks
2. Find `chunk_0` (0-13194) and `chunk_13194` (13194-65537)
3. Sort chunks by offset: [`chunk_0`, `chunk_13194`]
4. Iterate:
   - `chunk_0`: Skip (ends at 13194, request starts at 65536)
   - `chunk_13194`: ✅ Contains bytes 13194-65537
5. Load `chunk_13194` (52343 bytes)
6. Calculate: `startInChunk = 65536 - 13194 = 52342`, `endInChunk = 52343`
7. Extract: `subdata(in: 52342..<52343)` = 1 byte ✅
8. Continue loading more chunks for remaining request
9. Result: ✅ Serve from cache (no network needed)

## Impact Before Fix

### Symptoms
1. **Bandwidth waste**: Re-downloading already cached data
2. **Slower playback**: Network latency vs instant cache
3. **Offline broken**: Can't play cached videos offline
4. **Battery drain**: Network activity vs cache read
5. **Misleading logs**: Shows "No data available" even though data is cached

### From Logs (Before Fix)
```
📦 Cache hit for BigBuckBunny.mp4: 4.91 MB in 1 range(s)
🔍 Data request: range=65536-158008374, cached ranges: 1
❌ No data available for range 65536-158008374
🌐 Request: bytes=65536- for BigBuckBunny.mp4  ← UNNECESSARY!
```

**Reality**: Bytes 65536-5152261 (~4.85 MB) were cached but not served!

### After Fix (Expected)
```
📦 Cache hit for BigBuckBunny.mp4: 4.91 MB in 1 range(s)
🔍 Data request: range=65536-158008374, cached ranges: 1
📥 Retrieved 52343 bytes from chunk at 13194
📥 Retrieved 129680 bytes from chunk at 65536
📥 Retrieved (more chunks...)
✅ Complete range retrieved: 4.85 MB from 65536
```

## Testing Procedure

### Test 1: Online Resume (should now use cache)
1. Play Video 1 for 10s (caches ~5MB)
2. Switch to Video 2
3. Return to Video 1
4. **Expected**: Logs show "Retrieved X MB from chunk at Y"
5. **Expected**: Less network activity
6. **Expected**: Faster playback start

### Test 2: Offline Resume (should now work!)
1. Play Video 1 for 10s with network
2. Close app
3. **Disable network** (Airplane mode)
4. Relaunch app
5. Play Video 1
6. **Expected**: Video plays from cache
7. **Expected**: Logs show cache retrieval
8. **Expected**: No "Internet offline" error

### Test 3: Bandwidth Savings
1. Clear cache
2. Play Video 1 for 10s (caches ~5MB)
3. Monitor network: Note MB downloaded
4. Return to Video 1
5. Monitor network again
6. **Expected**: Significantly less network usage (should only download new data beyond cached)

## Files Modified

- **PINCacheAssetDataManager.swift**:
  - `retrieveDataInRange()`: Complete rewrite to handle multiple chunks in merged ranges
  - `getAllChunkKeys()`: New helper to scan and find all chunks within ranges

## Build Status

✅ **BUILD SUCCEEDED** - No compilation errors
✅ Only existing warnings (Sendable, deprecated APIs - not related to changes)

## Success Metrics

| Metric | Before | After (Expected) |
|--------|--------|------------------|
| Cache retrieval from merged range | ❌ Fails | ✅ Works |
| Bandwidth on resume | 100% re-download | ~3% new data only |
| Offline playback | ❌ Broken | ✅ Works |
| Cache utilization | 0.0% effective | 100% effective |

## Key Insights

1. **Merged ranges ≠ Single chunk**: Range metadata merges, but chunks stay separate
2. **Network masked the bug**: Re-downloads succeeded, hiding cache failure
3. **Offline testing exposed it**: Network failure revealed cache wasn't working
4. **Architecture is sound**: Only needed to walk through individual chunks

The fix maintains the range-based architecture while properly handling the storage reality that merged ranges consist of multiple independent chunks.
