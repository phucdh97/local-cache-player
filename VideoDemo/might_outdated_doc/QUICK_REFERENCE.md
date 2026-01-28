# Quick Reference: Verifying Chunk Retrieval Fix

## What Was Fixed
Changed from sequential chunk search (with off-by-one bug) to direct lookup using tracked chunk offsets.

## New Logs to Watch

### 📌 Chunk Offset Tracking (Save Phase)
```
💾 Stored chunk with key: BigBuckBunny.mp4_chunk_65536, size: 121.58 KB
📌 Added chunk offset 64.00 KB, total offsets: 3
📌 Tracked offsets: [0 bytes, 7.42 KB, 64.00 KB]
```
✅ **Good:** Offsets list grows, no duplicates  
❌ **Bad:** Duplicate warnings, offsets not increasing

### 🔍 Chunk Scanning (Load Phase)
```
🔍 getAllChunkKeys: Scanning 3 tracked chunk offset(s)
🔍   ✅ Chunk at 0 bytes: 7.42 KB
🔍   ✅ Chunk at 7.42 KB: 56.58 KB
🔍   ✅ Chunk at 64.00 KB: 118.84 KB
🔍 getAllChunkKeys: Found 3/3 chunks
```
✅ **Good:** Found X/X chunks (all found)  
❌ **Bad:** Found X/Y with missing chunks warning

### 📥 Chunk Retrieval (Load Phase)
```
📥 Retrieved 7.42 KB from chunk at 0 bytes
📥 Retrieved 56.58 KB from chunk at 7.42 KB
📥 Retrieved 118.84 KB from chunk at 64.00 KB
⚡️ Partial range retrieved: 182.84 KB from 0 bytes
```
✅ **Good:** Multiple "Retrieved" logs, total matches cached size  
❌ **Bad:** Only one or two retrievals, total much less than cached

## One-Minute Verification

### Test 1: Save Phase ✓
1. Launch app with network
2. Play video for 10 seconds
3. Check console for "💾 Stored chunk" (should see multiple)
4. Check "📌 Tracked offsets" list grows
5. Note final offset count (e.g., 3 chunks)

### Test 2: Load Phase ✓
1. Stop app
2. Disable network (Airplane mode)
3. Launch app and play same video
4. Check "Found X/X chunks" - should be equal (e.g., 3/3)
5. Count "📥 Retrieved" logs - should match chunk count
6. Check total retrieved matches cached size

## Success Criteria

| Check | Expected | Location |
|-------|----------|----------|
| Chunks saved | See "💾 Stored" for each | First launch |
| Offsets tracked | "📌 Tracked offsets" grows | First launch |
| Chunks found | "Found X/X" (equal) | Second launch |
| All retrieved | X "📥 Retrieved" logs | Second launch |
| Size matches | Total = cached size | Second launch |

## Quick Troubleshooting

**"Found 2/3 chunks (⚠️ 1 missing)"**  
→ Look for "tracked but data missing" log  
→ Chunk metadata saved but data wasn't  
→ Try: Clear cache and re-test

**Only 64 KB retrieved (should be 180+ KB)**  
→ Check if third chunk was found  
→ Verify "📌 Tracked offsets" has all 3 offsets  
→ Bug not fixed or cache is old format

**No chunks found at all**  
→ Check "📌 Available chunk offsets" is not empty  
→ May need to clear old cache  
→ Ensure using new code with chunkOffsets

## Before vs After

### Before (Bug)
```
Found 2/3 chunks (⚠️ 1 missing)       ← Missing chunk!
Retrieved 64.00 KB                     ← Only 64 KB
```

### After (Fixed)
```
Found 3/3 chunks                       ← All found!
Retrieved 182.84 KB                    ← All data!
```

## Files Modified
- `AssetData.swift` - Added chunkOffsets array
- `PINCacheAssetDataManager.swift` - Enhanced tracking + logging

## Documentation
- `CHUNK_RETRIEVAL_FIX.md` - Detailed explanation
- `LOGGING_GUIDE.md` - All log messages explained
- `ENHANCED_LOGGING_SUMMARY.md` - What was added
- `TEST_CHUNK_RETRIEVAL.md` - Test cases
