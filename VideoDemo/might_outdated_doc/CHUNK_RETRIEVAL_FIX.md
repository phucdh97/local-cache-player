# Chunk Retrieval Bug Fix

## Problem Summary

When launching the app offline after caching data, only 64 KB of cached data was being retrieved instead of the full 185.58 KB that was actually cached.

## Root Cause

The `getAllChunkKeys()` method in `PINCacheAssetDataManager` had a flawed search algorithm:

1. **Sequential search assumption**: The method assumed chunks were stored sequentially without gaps
2. **Offset calculation bug**: It incremented the search offset by the chunk size, causing off-by-one errors
3. **Early termination**: When a chunk wasn't found at the expected offset, it stopped searching entirely

### Example of the Bug:

Cached chunks:
- `chunk_0` at offset 0 (13,194 bytes)
- `chunk_13194` at offset 13,194 (52,343 bytes)
- `chunk_65536` at offset 65,536 (124,502 bytes)

Search progression:
1. Find `chunk_0` (13,194 bytes) ✅
2. Search at offset 0 + 13,194 = 13,194 → Find `chunk_13194` ✅
3. Search at offset 13,194 + 52,343 = **65,537** → NOT FOUND ❌ (actual chunk is at 65,536)
4. **Break and return only 64 KB!**

## Solution

Added a `chunkOffsets` array to the `AssetData` class to explicitly track the actual offsets where chunks are stored.

### Changes Made:

#### 1. AssetData.swift
- Added `chunkOffsets: [NSNumber]` property to track actual chunk locations
- Updated `init(coder:)` and `encode(with:)` to persist chunk offsets

#### 2. PINCacheAssetDataManager.swift
- **saveDownloadedData()**: Now adds chunk offsets to the `chunkOffsets` array when saving
- **getAllChunkKeys()**: Rewritten to use the tracked offsets instead of sequential search
- **Migration support**: Old caches are automatically migrated to include chunk offset tracking

## Benefits

1. **Accurate retrieval**: All cached chunks are now found and retrieved correctly
2. **No off-by-one errors**: Uses exact tracked offsets instead of calculated ones
3. **Gap tolerance**: Works correctly even when chunks have gaps between them
4. **Backward compatible**: Old caches are automatically migrated

## Testing

To verify the fix:

1. **Clear existing cache** (to start fresh with the new metadata):
   - Delete app or clear app data
   
2. **First launch with network**:
   - Launch app and play a video
   - Let it download for ~10 seconds
   - Check logs for "✅ Chunk cached" messages
   - Note the total cached size (e.g., "185.58 KB in 1 range(s)")

3. **Second launch offline**:
   - Stop the app
   - Disable network connection
   - Launch app and play the same video
   - Verify that ALL cached data is retrieved (not just 64 KB)
   - Check logs for "📥 Retrieved X KB from chunk at Y" messages

Expected log output:
```
📦 Cache hit for BigBuckBunny.mp4: 185.58 KB in 1 range(s), contentLength=150.69 MB
📥 Retrieved 12.88 KB from chunk at 0 bytes (range 0 bytes-12.88 KB)
📥 Retrieved 51.12 KB from chunk at 12.88 KB (range 12.88 KB-64.00 KB)
📥 Retrieved 121.58 KB from chunk at 64.00 KB (range 64.00 KB-185.58 KB)
✅ Complete range retrieved: 185.58 KB from 0 bytes
```

## Migration Notes

- Existing caches will be automatically migrated when first accessed
- The migration adds chunk offset tracking to old cache entries
- No data loss occurs during migration
- If issues occur, clearing the cache will force a fresh download with proper tracking
