# Enhanced Cancellation Flow Logging

## Added Logs to Track Request Lifecycle

This document explains the enhanced logging added to understand exactly when and why data is saved, especially during video switching and app termination.

---

## New Log Flow

### 1. Request Starts
```
🌐 Request START: bytes=0-1 for BigBuckBunny.mp4, type: data
🌐 URLSession task started for BigBuckBunny.mp4
```
**When:** URLSession request begins
**Shows:** Range requested, request type (data/info), file name

---

### 2. Data Reception
```
📥 Received chunk: 43.75 KB, accumulated: 512.00 KB for BigBuckBunny.mp4
```
**When:** Each time data arrives from network
**Shows:** Chunk size, total accumulated in memory

**New:** If cancelled flag is set:
```
⚠️ Received chunk AFTER cancel for BigBuckBunny.mp4, ignoring
```

---

### 3. AVPlayer Requests Cancellation
```
❌ AVPlayer didCancel callback for BigBuckBunny.mp4
❌   Active requests before removal: 2
❌   Calling ResourceLoaderRequest.cancel()...
❌   Active requests after removal: 1
```
**When:** AVPlayer cancels a loading request (user switches video, seeks, or stops)
**Shows:** How many requests are active before/after cancellation

---

### 4. Cancel Method Called
```
🚫 cancel() called for BigBuckBunny.mp4, accumulated: 5.44 MB, type: data
🚫 cancel() setting isCancelled=true, will trigger dataTask.cancel()
```
**When:** `ResourceLoaderRequest.cancel()` is invoked
**Shows:** 
- How much data was accumulated before cancel
- Request type
- That URLSession cancellation will be triggered

---

### 5. isCancelled Property Triggers URLSession Cancel
```
🔴 isCancelled didSet triggered for BigBuckBunny.mp4
🔴 Calling dataTask.cancel() and session.invalidateAndCancel()
🔴 URLSession cancellation triggered, waiting for didCompleteWithError callback...
```
**When:** `isCancelled` property is set to true
**Shows:** URLSession's `cancel()` is called, which will eventually trigger completion callback

---

### 6. URLSession Completion Callback
```
⏹️ didCompleteWithError called for BigBuckBunny.mp4
⏹️   Error: cancelled
⏹️   Type: data, Downloaded: 5.44 MB
⏹️   isCancelled: true, isFinished: false
```
**When:** URLSession task completes (success, error, or cancellation)
**Shows:**
- Whether it was an error or success
- How much data was downloaded
- Current state flags

---

### 7. Data Save Process
```
💿 Data request completion handler
💿   Request range: 187238 to requestToEnd
💿   Downloaded data size: 5.44 MB
💾 Saving 5.44 MB at offset 187238 for BigBuckBunny.mp4
💾   This includes ALL accumulated data from this request
✅ Save completed, notifying delegate
💿 Data request completion handler finished
```
**When:** Saving accumulated data to cache
**Shows:**
- Request offset and range
- Total data being saved
- Confirmation of save completion

---

### 8. ResourceLoader Cleanup (Video Switch)
```
♻️ ResourceLoader deinit for BigBuckBunny.mp4
♻️   Cancelling 2 active request(s)
♻️   Cancelling request with accumulated data: 3.22 MB
♻️   Cancelling request with accumulated data: 1.15 MB
♻️ ResourceLoader deinit completed for BigBuckBunny.mp4
```
**When:** Video is switched or player is destroyed
**Shows:**
- How many requests are being cancelled
- How much data each request had accumulated
- When cleanup is complete

---

## Complete Flow Examples

### Scenario 1: Normal Video Switch (Data Saved ✅)

```
[User playing BigBuckBunny]
📥 Received chunk: 45.12 KB, accumulated: 5.30 MB for BigBuckBunny.mp4
📥 Received chunk: 24.61 KB, accumulated: 5.37 MB for BigBuckBunny.mp4

[User switches to ElephantsDream]
🛑 Stopping all downloads
♻️ ResourceLoader deinit for BigBuckBunny.mp4
♻️   Cancelling 2 active request(s)
♻️   Cancelling request with accumulated data: 5.44 MB

🚫 cancel() called for BigBuckBunny.mp4, accumulated: 5.44 MB, type: data
🔴 isCancelled didSet triggered for BigBuckBunny.mp4
🔴 Calling dataTask.cancel() and session.invalidateAndCancel()
🔴 URLSession cancellation triggered, waiting for didCompleteWithError callback...

[URLSession processes cancellation]
⏹️ didCompleteWithError called for BigBuckBunny.mp4
⏹️   Error: cancelled
⏹️   Type: data, Downloaded: 5.44 MB

💿 Data request completion handler
💾 Saving 5.44 MB at offset 187238 for BigBuckBunny.mp4
✅ Save completed, notifying delegate
💿 Data request completion handler finished
```

**Result:** 5.44 MB saved ✅

---

### Scenario 2: Force Quit App (Data Lost ❌)

```
[User playing BigBuckBunny]
📥 Received chunk: 72.46 KB, accumulated: 9.97 MB for BigBuckBunny.mp4
📥 Received chunk: 41.02 KB, accumulated: 10.01 MB for BigBuckBunny.mp4

[User force-quits app - NO LOGS]
(Process killed by iOS, no cleanup code runs)
```

**Result:** 10.01 MB lost ❌

---

### Scenario 3: AVPlayer Seeks (Small Requests Complete Quickly)

```
🌐 Request START: bytes=0-1 for BigBuckBunny.mp4, type: data
📥 Received chunk: 2 bytes, accumulated: 2 bytes
⏹️ didCompleteWithError called for BigBuckBunny.mp4
⏹️   Error: nil (success)
💾 Saving 2 bytes at offset 0 for BigBuckBunny.mp4
✅ Save completed
```

**Result:** Small requests complete normally ✅

---

## Key Patterns to Look For

### Pattern 1: Request Completes Before Cancel
```
📥 Received chunk: ... accumulated: 118.85 KB
⏹️ didCompleteWithError called (success)
💾 Saving 118.85 KB
[Later, another request...]
```
**Meaning:** Request finished naturally, data saved ✅

---

### Pattern 2: Request Cancelled During Download
```
📥 Received chunk: ... accumulated: 5.44 MB
🚫 cancel() called, accumulated: 5.44 MB
🔴 isCancelled didSet triggered
⏹️ didCompleteWithError called (error: cancelled)
💾 Saving 5.44 MB
```
**Meaning:** Cancelled but saved via completion callback ✅

---

### Pattern 3: Chunks After Cancel (Race Condition)
```
🚫 cancel() called
📥 Received chunk AFTER cancel, ignoring
📥 Received chunk AFTER cancel, ignoring
⏹️ didCompleteWithError called
```
**Meaning:** Network chunks still arriving after cancel, safely ignored ⚠️

---

### Pattern 4: No Completion Callback (Force Quit)
```
📥 Received chunk: ... accumulated: 10.01 MB
[NO MORE LOGS - app killed]
```
**Meaning:** Process terminated, data lost ❌

---

## What to Check in New Logs

1. **Count saves vs accumulated data:**
   - Look for all "💾 Saving X MB" logs
   - Sum them up
   - Compare to highest "accumulated" value before app stop
   - Difference = data lost

2. **Verify completion callbacks:**
   - Every "🔴 URLSession cancellation triggered" should have a matching "⏹️ didCompleteWithError"
   - If missing, URLSession callback didn't happen

3. **Check timing:**
   - "📥 Received chunk" after "🚫 cancel()" = race condition (safe, ignored)
   - "📥 Received chunk" with no subsequent "💾 Saving" = data lost

4. **Active request tracking:**
   - "♻️ Cancelling 2 active request(s)" shows how many concurrent downloads
   - Each should trigger its own save sequence

---

## Testing Instructions

### Test 1: Video Switch (Should Save)
1. Play BigBuckBunny for 10 seconds
2. Switch to ElephantsDream
3. Check logs for sequence:
   ```
   ♻️ ResourceLoader deinit
   🚫 cancel() called
   🔴 isCancelled didSet
   ⏹️ didCompleteWithError
   💾 Saving
   ```
4. Expected: All accumulated data saved ✅

### Test 2: Force Quit (Will Lose Data)
1. Play BigBuckBunny for 10 seconds
2. Note highest "accumulated" value (e.g., 9.97 MB)
3. Force quit app
4. Relaunch and check cache
5. Expected: Cache < accumulated (data lost) ❌

### Test 3: Background/Home Button
1. Play BigBuckBunny for 10 seconds
2. Press Home button
3. Check logs immediately
4. Expected: May or may not trigger deinit (iOS dependent) ⚠️

---

## Summary of Added Logs

| Emoji | Location | What It Shows |
|-------|----------|---------------|
| 🌐 | Request start | When URLSession begins |
| 🚫 | cancel() | Cancellation requested |
| 🔴 | isCancelled didSet | URLSession being cancelled |
| ⏹️ | didCompleteWithError | Completion callback fired |
| 💿 | Data completion | Save process starting |
| 💾 | saveDownloadedData | Data being written to cache |
| ✅ | After save | Save confirmed |
| ♻️ | deinit | Cleanup on video switch |
| ❌ | AVPlayer cancel | AVPlayer cancelled request |
| ⚠️ | Edge cases | Unusual situations |

---

## Files Modified

1. **ResourceLoaderRequest.swift**
   - `start()` - Log request beginning
   - `cancel()` - Log cancellation request
   - `isCancelled didSet` - Log URLSession cancellation
   - `urlSession(_:dataTask:didReceive:)` - Check for post-cancel chunks
   - `urlSession(_:task:didCompleteWithError:)` - Detailed completion info
   - Data save section - Detailed save process

2. **ResourceLoader.swift**
   - `resourceLoader(_:didCancel:)` - Log AVPlayer cancellation
   - `deinit` - Log cleanup with accumulated data sizes
