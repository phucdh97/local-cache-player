# **Detailed Flow: ResourceLoaderRequest Lifecycle**

## **Overview: The Complete Journey**

```
AVPlayer Request → Check Cache → Start Download → Receive Data → Cache → Respond → Finish Loading
```

Let me break this down step by step with code examples.

---

## **THREAD SAFETY: loaderQueue Usage**

The `loaderQueue` (a serial dispatch queue) is used in **two critical places** to ensure thread-safe access to shared state:

1. **`resourceLoader.setDelegate(self, queue: loaderQueue)`** - Tells AVFoundation to call all delegate methods on this queue
2. **`ResourceLoaderRequest(..., loaderQueue: self.loaderQueue)`** - Ensures URLSession callbacks dispatch back to the same queue

**Why this matters:**
- AVFoundation calls delegates from one thread
- URLSession delivers data on background threads
- Multiple concurrent requests may be in flight simultaneously
- The **same serial queue** synchronizes all access to: `requests` dictionary, `downloadedData`, cache operations, and `AVAssetResourceLoadingRequest` state

**Result:** No race conditions, no locks needed - all operations are naturally serialized on `loaderQueue`.

---

## **PHASE 1: REQUEST ARRIVAL & CACHE CHECK**

### Step 1: AVPlayer Makes a Request

When AVPlayer needs data, it calls this delegate method in [ResourceLoader.swift:33](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L33):

```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool
```

**Key Parameters:**
- `loadingRequest`: An `AVAssetResourceLoadingRequest` object representing what AVPlayer wants
- **Return value**: `true` means "Yes, wait for me to provide the data", `false` means "I can't handle this"

### Step 2: Determine Request Type

From [ResourceLoader.swift:35](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L35):

```swift
let type = ResourceLoader.resourceLoaderRequestType(loadingRequest)
```

This checks (from [ResourceLoader.swift:127-133](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L127-L133)):

```swift
static func resourceLoaderRequestType(_ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequest.RequestType {
    if let _ = loadingRequest.contentInformationRequest {
        return .contentInformation  // First request - get metadata
    } else {
        return .dataRequest         // Subsequent requests - get actual data
    }
}
```

### Step 3: Initialize Cache Manager

From [ResourceLoader.swift:36](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L36):

```swift
let assetDataManager = PINCacheAssetDataManager(cacheKey: self.cacheKey)
// cacheKey is typically the filename: "video.mp4"
```

### Step 4: Check Cache

From [ResourceLoader.swift:38-68](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L38-L68):

```swift
if let assetData = assetDataManager.retrieveAssetData() {
    // CACHE EXISTS - Let's see what we have
```

**Cache retrieval** ([PINCacheAssetDataManager.swift:38-43](resourceLoaderDemo/ResourceLoader/PINCacheAssetDataManager.swift#L38-L43)):

```swift
func retrieveAssetData() -> AssetData? {
    guard let assetData = PINCacheAssetDataManager.Cache.object(forKey: cacheKey) as? AssetData else {
        return nil  // No cache
    }
    return assetData  // Returns cached data
}
```

**What's in `AssetData`?**
```swift
struct AssetData {
    var contentInformation: AssetDataContentInformation  // Metadata: size, type, etc.
    var mediaData: Data                                   // Actual video/audio bytes
}
```

#### **Scenario A: Content Information Request with Cache HIT**

From [ResourceLoader.swift:39-44](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L39-L44):

```swift
if type == .contentInformation {
    // We have cached metadata - return it immediately!
    loadingRequest.contentInformationRequest?.contentLength = assetData.contentInformation.contentLength
    loadingRequest.contentInformationRequest?.contentType = assetData.contentInformation.contentType
    loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = assetData.contentInformation.isByteRangeAccessSupported
    loadingRequest.finishLoading()  // ← IMPORTANT: Tell AVPlayer "I'm done!"
    return true  // Exit early - no network request needed
}
```

#### **Scenario B: Data Request with FULL Cache HIT**

From [ResourceLoader.swift:46-60](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L46-L60):

```swift
let range = ResourceLoader.resourceLoaderRequestRange(type, loadingRequest)
// Example: range = RequestRange(start: 65536, end: .requestTo(131071))

if assetData.mediaData.count > 0 {
    let end: Int64
    switch range.end {
    case .requestTo(let rangeEnd):
        end = rangeEnd           // Specific end: 131071
    case .requestToEnd:
        end = assetData.contentInformation.contentLength  // To end of file
    }

    // Do we have enough cached data to satisfy this request?
    if assetData.mediaData.count >= end {
        // YES! Serve from cache
        let subData = assetData.mediaData.subdata(in: Int(range.start)..<Int(end))
        loadingRequest.dataRequest?.respond(with: subData)  // ← Give data to AVPlayer
        loadingRequest.finishLoading()  // ← Tell AVPlayer "I'm done!"
        return true  // Exit early - no network request needed
    }
}
```

#### **Scenario C: Data Request with PARTIAL Cache HIT**

From [ResourceLoader.swift:61-66](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L61-L66):

```swift
else if range.start <= assetData.mediaData.count {
    // We have SOME cached data, but not enough
    // Example: Request wants bytes 65536-131071, but cache only has 0-90000

    let subEnd = (assetData.mediaData.count > end) ? Int((end)) : (assetData.mediaData.count)
    let subData = assetData.mediaData.subdata(in: Int(range.start)..<subEnd)

    loadingRequest.dataRequest?.respond(with: subData)  // ← Give partial data to AVPlayer

    // NOTE: We DON'T call finishLoading() here!
    // We'll continue to network request to get the rest
}
```

**Important**: When partially serving from cache, we **respond** with data but **don't finish loading**. This tells AVPlayer:
- "Here's some data to start with"
- "I'm still working on getting you the rest"

---

## **PHASE 2: START DOWNLOAD (Cache Miss or Partial Hit)**

### Step 5: Calculate Request Range

From [ResourceLoader.swift:71](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L71):

```swift
let range = ResourceLoader.resourceLoaderRequestRange(type, loadingRequest)
```

Implementation ([ResourceLoader.swift:135-149](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L135-L149)):

```swift
static func resourceLoaderRequestRange(_ type: ResourceLoaderRequest.RequestType,
                                      _ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequest.RequestRange {
    if type == .contentInformation {
        // For metadata, just request 1 byte (we only care about headers)
        return ResourceLoaderRequest.RequestRange(start: 0, end: .requestTo(1))
    } else {
        // For data requests, use what AVPlayer is requesting
        if loadingRequest.dataRequest?.requestsAllDataToEndOfResource == true {
            // AVPlayer wants everything from offset to end
            let lowerBound = loadingRequest.dataRequest?.currentOffset ?? 0
            return ResourceLoaderRequest.RequestRange(start: lowerBound, end: .requestToEnd)
        } else {
            // AVPlayer wants a specific range
            let lowerBound = loadingRequest.dataRequest?.currentOffset ?? 0
            let length = Int64(loadingRequest.dataRequest?.requestedLength ?? 1)
            let upperBound = lowerBound + length
            return ResourceLoaderRequest.RequestRange(start: lowerBound, end: .requestTo(upperBound))
        }
    }
}
```

**Example output:**
```swift
// Content Info: RequestRange(start: 0, end: .requestTo(1))
// Data Request: RequestRange(start: 65536, end: .requestTo(131071))
// To End:       RequestRange(start: 1048576, end: .requestToEnd)
```

### Step 6: Create ResourceLoaderRequest

From [ResourceLoader.swift:72-73](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L72-L73):

```swift
let resourceLoaderRequest = ResourceLoaderRequest(
    originalURL: self.originalURL,        // http://example.com/video.mp4
    type: type,                           // .contentInformation or .dataRequest
    loaderQueue: self.loaderQueue,        // Serial queue for thread safety
    assetDataManager: assetDataManager    // Cache manager
)
resourceLoaderRequest.delegate = self  // ResourceLoader will receive callbacks
```

### Step 7: Store in Requests Dictionary

From [ResourceLoader.swift:74-75](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L74-L75):

```swift
self.requests[loadingRequest]?.cancel()           // Cancel any existing request for this
self.requests[loadingRequest] = resourceLoaderRequest  // Store new request
```

**Why this dictionary?**

```swift
private var requests: [AVAssetResourceLoadingRequest: ResourceLoaderRequest] = [:]
```

This maps:
- **Key**: AVPlayer's `AVAssetResourceLoadingRequest` (what AVPlayer wants)
- **Value**: Our `ResourceLoaderRequest` (our network operation to fulfill it)

**Purpose:**
1. **Track active requests**: Multiple requests can be in flight simultaneously
2. **Cancel on demand**: When AVPlayer cancels a request (e.g., user seeks), we can find and cancel the corresponding network request
3. **Delegate callbacks**: When network data arrives, we can find the original AVPlayer request to respond to

**Example state:**
```
requests = [
    AVAssetLoadingRequest(range: 0-64K)    → ResourceLoaderRequest(downloading...),
    AVAssetLoadingRequest(range: 64K-128K) → ResourceLoaderRequest(downloading...),
    AVAssetLoadingRequest(range: 128K-192K) → ResourceLoaderRequest(downloading...)
]
```

### Step 8: Start the Network Request

From [ResourceLoader.swift:76](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L76):

```swift
resourceLoaderRequest.start(requestRange: range)
```

---

## **PHASE 3: NETWORK REQUEST EXECUTION**

### Step 9: Start Method Implementation

From [ResourceLoaderRequest.swift:74-104](resourceLoaderDemo/ResourceLoader/ResourceLoaderRequest.swift#L74-L104):

```swift
func start(requestRange: RequestRange) {
    // Safety check: Don't start if already cancelled or finished
    guard isCancelled == false, isFinished == false else {
        return
    }

    // CRITICAL: Dispatch to serial queue for thread safety
    self.loaderQueue.async { [weak self] in
        guard let self = self else {
            return
        }

        // 1. Create URLRequest with original URL
        var request = URLRequest(url: self.originalURL)
        self.requestRange = requestRange

        // 2. Build Range header
        let start = String(requestRange.start)
        let end: String
        switch requestRange.end {
        case .requestTo(let rangeEnd):
            end = String(rangeEnd)        // "131071"
        case .requestToEnd:
            end = ""                      // Empty means "to end"
        }

        let rangeHeader = "bytes=\(start)-\(end)"
        // Examples:
        // "bytes=0-1"           (content info)
        // "bytes=65536-131071"  (specific range)
        // "bytes=1048576-"      (from offset to end)

        request.setValue(rangeHeader, forHTTPHeaderField: "Range")

        // 3. Create URLSession with self as delegate
        let session = URLSession(configuration: .default,
                                delegate: self,        // Receive URLSession callbacks
                                delegateQueue: nil)    // nil = background thread
        self.session = session

        // 4. Create and start data task
        let dataTask = session.dataTask(with: request)
        self.dataTask = dataTask
        dataTask.resume()  // ← Start downloading!
    }
}
```

**HTTP Request Example:**
```http
GET /video.mp4 HTTP/1.1
Host: example.com
Range: bytes=65536-131071
```

**Server Response:**
```http
HTTP/1.1 206 Partial Content
Content-Range: bytes 65536-131071/5242880
Content-Length: 65536
Content-Type: video/mp4
Accept-Ranges: bytes

[binary data...]
```

---

## **PHASE 4: RECEIVE RESPONSE & DATA**

### Step 10: Receive Response Headers

From [ResourceLoaderRequest.swift:121-124](resourceLoaderDemo/ResourceLoader/ResourceLoaderRequest.swift#L121-L124):

```swift
func urlSession(_ session: URLSession,
               dataTask: URLSessionDataTask,
               didReceive response: URLResponse,
               completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    self.response = response  // Store for later parsing
    completionHandler(.allow) // Tell URLSession to continue
}
```

### Step 11: Receive Data Chunks (STREAMING!)

This is called **multiple times** as data arrives from the network.

From [ResourceLoaderRequest.swift:110-119](resourceLoaderDemo/ResourceLoader/ResourceLoaderRequest.swift#L110-L119):

```swift
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    // Only handle data for data requests (not content info requests)
    guard self.type == .dataRequest else {
        return
    }

    // ALWAYS dispatch back to serial queue for thread safety
    self.loaderQueue.async {
        // 1. Immediately forward to AVPlayer (streaming)
        self.delegate?.dataRequestDidReceive(self, data)

        // 2. Accumulate for caching later
        self.downloadedData.append(data)
    }
}
```

**This method is the KEY to streaming!**

**Example timeline:**
```
Time 0ms:   didReceive data: 8KB  → Stream to AVPlayer + Store
Time 50ms:  didReceive data: 16KB → Stream to AVPlayer + Store
Time 100ms: didReceive data: 12KB → Stream to AVPlayer + Store
Time 150ms: didReceive data: 8KB  → Stream to AVPlayer + Store
...
```

### Step 12: Delegate Callback to ResourceLoader

The delegate call goes to [ResourceLoader.swift:108-114](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L108-L114):

```swift
func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequest, _ data: Data) {
    // Find the original AVPlayer loading request
    guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
        return  // Request was cancelled
    }

    // Send data to AVPlayer IMMEDIATELY
    loadingRequest.dataRequest?.respond(with: data)
}
```

**This is how AVPlayer receives data while download is in progress!**

---

## **PHASE 5: COMPLETION & CACHING**

### Step 13: Request Completes

From [ResourceLoaderRequest.swift:126-166](resourceLoaderDemo/ResourceLoader/ResourceLoaderRequest.swift#L126-L166):

```swift
func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    self.isFinished = true  // This triggers session cleanup (line 56-61)

    self.loaderQueue.async {
        if self.type == .contentInformation {
            // ═══════════════════════════════════════════
            // CONTENT INFORMATION REQUEST COMPLETION
            // ═══════════════════════════════════════════

            guard error == nil,
                  let response = self.response as? HTTPURLResponse else {
                let responseError = error ?? ResponseUnExpectedError()
                self.delegate?.contentInformationDidComplete(self, .failure(responseError))
                return
            }

            let contentInformation = AssetDataContentInformation()

            // Parse Content-Range header: "bytes 0-1/5242880"
            if let rangeString = response.allHeaderFields["Content-Range"] as? String,
               let bytesString = rangeString.split(separator: "/").map({String($0)}).last,
               let bytes = Int64(bytesString) {
                contentInformation.contentLength = bytes  // 5242880 = 5MB
            }

            // Parse Content-Type: "video/mp4" → convert to UTType
            if let mimeType = response.mimeType,
               let contentType = UTTypeCreatePreferredIdentifierForTag(
                   kUTTagClassMIMEType, mimeType as CFString, nil)?.takeRetainedValue() {
                contentInformation.contentType = contentType as String
            }

            // Parse Accept-Ranges: "bytes"
            if let value = response.allHeaderFields["Accept-Ranges"] as? String,
               value == "bytes" {
                contentInformation.isByteRangeAccessSupported = true
            }

            // SAVE TO CACHE
            self.assetDataManager?.saveContentInformation(contentInformation)

            // Notify delegate
            self.delegate?.contentInformationDidComplete(self, .success(contentInformation))

        } else {
            // ═══════════════════════════════════════════
            // DATA REQUEST COMPLETION
            // ═══════════════════════════════════════════

            // SAVE TO CACHE
            if let offset = self.requestRange?.start, self.downloadedData.count > 0 {
                self.assetDataManager?.saveDownloadedData(self.downloadedData, offset: Int(offset))
            }

            // Notify delegate
            self.delegate?.dataRequestDidComplete(self, error, self.downloadedData)
        }
    }
}
```

### Step 14: Save Content Information to Cache

From [PINCacheAssetDataManager.swift:20-24](resourceLoaderDemo/ResourceLoader/PINCacheAssetDataManager.swift#L20-L24):

```swift
func saveContentInformation(_ contentInformation: AssetDataContentInformation) {
    let assetData = AssetData()
    assetData.contentInformation = contentInformation

    // Async write to cache (memory + disk)
    PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
}
```

### Step 15: Save Downloaded Data to Cache

From [PINCacheAssetDataManager.swift:26-36](resourceLoaderDemo/ResourceLoader/PINCacheAssetDataManager.swift#L26-L36):

```swift
func saveDownloadedData(_ data: Data, offset: Int) {
    // 1. Retrieve existing cache
    guard let assetData = self.retrieveAssetData() else {
        return  // No content info yet - can't save data without metadata
    }

    // 2. Merge new data with existing data
    if let mediaData = self.mergeDownloadedDataIfIsContinuted(
        from: assetData.mediaData,
        with: data,
        offset: offset) {

        assetData.mediaData = mediaData

        // 3. Save back to cache
        PINCacheAssetDataManager.Cache.setObjectAsync(assetData, forKey: cacheKey, completion: nil)
    }
}
```

**The merge logic** (inferred from the method name `mergeDownloadedDataIfIsContinuted`):

```
Scenario 1: Sequential download
  Existing: [0...........65536]
  New data: [65536.......131072] (offset: 65536)
  Result:   [0.....................131072]  ← Append

Scenario 2: Non-sequential (gap)
  Existing: [0...........65536]
  New data: [131072......196608] (offset: 131072)
  Result:   [0...........65536]            ← Can't merge, discard new data
  (Gap at 65536-131072 prevents merging)

Scenario 3: Overlapping
  Existing: [0...........100000]
  New data: [65536.......131072] (offset: 65536)
  Result:   [0.....................131072]  ← Merge overlap
```

**Why this strategy?** The implementation only supports **sequential downloads** to keep cache simple and avoid fragmentation.

---

## **PHASE 6: FINISH LOADING**

### Step 16: Notify ResourceLoader (Content Info)

From [ResourceLoader.swift:92-106](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L92-L106):

```swift
func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest,
                                   _ result: Result<AssetDataContentInformation, Error>) {
    // Find the original AVPlayer request
    guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
        return
    }

    switch result {
    case .success(let contentInformation):
        // Populate AVPlayer's content information request
        loadingRequest.contentInformationRequest?.contentType = contentInformation.contentType
        loadingRequest.contentInformationRequest?.contentLength = contentInformation.contentLength
        loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = contentInformation.isByteRangeAccessSupported

        // ← FINISH LOADING - Tell AVPlayer we're done
        loadingRequest.finishLoading()

    case .failure(let error):
        // ← FINISH LOADING WITH ERROR
        loadingRequest.finishLoading(with: error)
    }
}
```

### Step 17: Notify ResourceLoader (Data Request)

From [ResourceLoader.swift:116-123](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L116-L123):

```swift
func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest,
                           _ error: Error?,
                           _ downloadedData: Data) {
    // Find the original AVPlayer request
    guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
        return
    }

    // ← FINISH LOADING (with optional error)
    loadingRequest.finishLoading(with: error)

    // Clean up - remove from active requests
    requests.removeValue(forKey: loadingRequest)
}
```

---

## **What is `finishLoading()`?**

`finishLoading()` is an **AVFoundation method** that tells AVPlayer:

```swift
// Success - I've provided all the data you requested
loadingRequest.finishLoading()

// Failure - Something went wrong
loadingRequest.finishLoading(with: error)
```

**What happens when you call it:**

1. **AVPlayer stops waiting** for this request
2. **AVPlayer processes the data** you provided via `respond(with:)`
3. **AVPlayer may make new requests** for more data
4. **If error**: AVPlayer may retry, stall, or fail depending on error severity

**Critical timing rules:**

```swift
// ✅ CORRECT: Respond with data, THEN finish
loadingRequest.dataRequest?.respond(with: data)
loadingRequest.finishLoading()

// ❌ WRONG: Finish before responding
loadingRequest.finishLoading()
loadingRequest.dataRequest?.respond(with: data)  // Too late! AVPlayer already moved on

// ✅ CORRECT: Partial response without finishing (streaming)
loadingRequest.dataRequest?.respond(with: chunk1)
loadingRequest.dataRequest?.respond(with: chunk2)
loadingRequest.dataRequest?.respond(with: chunk3)
loadingRequest.finishLoading()  // Only finish when ALL data is provided

// ✅ CORRECT: Finish immediately with cached data
loadingRequest.dataRequest?.respond(with: cachedData)
loadingRequest.finishLoading()  // Immediate finish
```

---

## **REQUEST CANCELLATION FLOW**

### When AVPlayer Cancels

AVPlayer might cancel a request when:
- User seeks to a different position
- User pauses and AVPlayer has buffered enough
- User closes the player

From [ResourceLoader.swift:81-88](resourceLoaderDemo/ResourceLoader/ResourceLoader.swift#L81-L88):

```swift
func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                   didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    guard let resourceLoaderRequest = self.requests[loadingRequest] else {
        return  // Already cleaned up
    }

    resourceLoaderRequest.cancel()  // Stop network request
    requests.removeValue(forKey: loadingRequest)  // Clean up dictionary
}
```

From [ResourceLoaderRequest.swift:106-108](resourceLoaderDemo/ResourceLoader/ResourceLoaderRequest.swift#L106-L108):

```swift
func cancel() {
    self.isCancelled = true  // This triggers cleanup (line 48-54)
}

private(set) var isCancelled: Bool = false {
    didSet {
        if isCancelled {
            self.dataTask?.cancel()           // Stop URLSession task
            self.session?.invalidateAndCancel()  // Cleanup session
        }
    }
}
```

---

## **COMPLETE FLOW DIAGRAM WITH CODE REFERENCES**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    AVPlayer Makes Request                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ ResourceLoader.swift:33                                                 │
│ shouldWaitForLoadingOfRequestedResource(loadingRequest)                 │
│                                                                         │
│ → Determine type: .contentInformation or .dataRequest  (line 35)       │
│ → Create cache manager: PINCacheAssetDataManager       (line 36)       │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓
┌─────────────────────────────────────────────────────────────────────────┐
│ ResourceLoader.swift:38 - Check Cache                                   │
│ if let assetData = assetDataManager.retrieveAssetData()                 │
└─────────────────────────────────────────────────────────────────────────┘
                    ↓                               ↓
        ┌───────────────────┐           ┌──────────────────┐
        │   CACHE HIT       │           │   CACHE MISS     │
        └───────────────────┘           └──────────────────┘
                    ↓                               ↓
┌─────────────────────────────────┐   ┌─────────────────────────────────┐
│ Content Info (lines 39-44)      │   │ ResourceLoader.swift:71-76      │
│ → Populate contentInfo          │   │ → Calculate range               │
│ → finishLoading()               │   │ → Create ResourceLoaderRequest  │
│ → return true ✓                 │   │ → Store in requests dict        │
│                                 │   │ → resourceLoaderRequest.start() │
│ Data Request (lines 56-60)      │   └─────────────────────────────────┘
│ → Extract subdata from cache    │               ↓
│ → respond(with: subData)        │   ┌─────────────────────────────────┐
│ → finishLoading()               │   │ ResourceLoaderRequest.swift:74  │
│ → return true ✓                 │   │ start(requestRange:)            │
│                                 │   │                                 │
│ Partial Hit (lines 61-66)       │   │ → Dispatch to loaderQueue       │
│ → respond(with: partialData)    │   │ → Build Range header            │
│ → DON'T finish                  │   │ → Create URLSession             │
│ → Continue to network... →      │   │ → dataTask.resume()             │
└─────────────────────────────────┘   └─────────────────────────────────┘
                                                   ↓
                              ┌─────────────────────────────────┐
                              │    Network Request Sent         │
                              │ GET /video.mp4                  │
                              │ Range: bytes=65536-131071       │
                              └─────────────────────────────────┘
                                          ↓
                              ┌─────────────────────────────────┐
                              │ ResourceLoaderRequest.swift:121 │
                              │ didReceive response             │
                              │ → Store response for parsing    │
                              └─────────────────────────────────┘
                                          ↓
                              ┌─────────────────────────────────┐
                              │ ResourceLoaderRequest.swift:110 │
                              │ didReceive data (MULTIPLE CALLS)│
                              │                                 │
                              │ → delegate.dataDidReceive()     │
                              │ → downloadedData.append()       │
                              └─────────────────────────────────┘
                                          ↓
                              ┌─────────────────────────────────┐
                              │ ResourceLoader.swift:108        │
                              │ dataRequestDidReceive()         │
                              │                                 │
                              │ → Find original loadingRequest  │
                              │ → respond(with: data)           │
                              │     ↓                           │
                              │   AVPlayer RECEIVES & PLAYS! ✓  │
                              └─────────────────────────────────┘
                                          ↓
                              ┌─────────────────────────────────┐
                              │ ResourceLoaderRequest.swift:126 │
                              │ didCompleteWithError            │
                              │                                 │
                              │ if .contentInformation:         │
                              │   → Parse headers (lines 137-155│
                              │   → Save to cache (line 157)    │
                              │   → delegate.contentInfoComplete│
                              │                                 │
                              │ if .dataRequest:                │
                              │   → Save to cache (line 161)    │
                              │   → delegate.dataComplete       │
                              └─────────────────────────────────┘
                                          ↓
                   ┌──────────────────────┴───────────────────────┐
                   ↓                                              ↓
┌───────────────────────────────────────┐  ┌──────────────────────────────┐
│ PINCacheAssetDataManager.swift:20     │  │ PINCacheAssetDataManager:26  │
│ saveContentInformation()              │  │ saveDownloadedData()         │
│                                       │  │                              │
│ → Create AssetData                    │  │ → Retrieve existing cache    │
│ → Save to PINCache                    │  │ → Merge with new data        │
└───────────────────────────────────────┘  │ → Save to PINCache           │
                   ↓                        └──────────────────────────────┘
                   │                                    ↓
                   └──────────────────┬─────────────────┘
                                      ↓
                   ┌─────────────────────────────────────┐
                   │ ResourceLoader.swift:92 & 116       │
                   │ Delegate callbacks                  │
                   │                                     │
                   │ → Populate loadingRequest           │
                   │ → loadingRequest.finishLoading()    │
                   │ → requests.removeValue()            │
                   └─────────────────────────────────────┘
                                      ↓
                   ┌─────────────────────────────────────┐
                   │     AVPlayer Notified - DONE! ✓     │
                   │                                     │
                   │ Next request may hit cache now!     │
                   └─────────────────────────────────────┘
```

---

## **SUMMARY: Key Concepts**

### 1. **requests Dictionary**
- **Purpose**: Track active network requests for AVPlayer's loading requests
- **Key**: `AVAssetResourceLoadingRequest` (what AVPlayer wants)
- **Value**: `ResourceLoaderRequest` (our network operation)
- **Lifecycle**: Created on start, removed on completion/cancellation

### 2. **start(requestRange:)**
- Creates `URLRequest` with `Range` header
- Dispatches to **serial queue** for thread safety
- Creates `URLSession` with self as delegate
- Starts `dataTask` to begin download

### 3. **Cache Flow**
- **Check**: Before network request
- **Save**: After download completes
- **Merge**: Sequential data is appended to existing cache
- **Serve**: Next requests hit cache first

### 4. **Response Flow**
- **Streaming**: `respond(with:)` called multiple times during download
- **Caching**: Data accumulated in `downloadedData` buffer
- **Completion**: `finishLoading()` signals AVPlayer we're done

### 5. **finishLoading()**
- **Tells AVPlayer**: "I've provided all the data for this request"
- **Timing**: Call AFTER all `respond(with:)` calls
- **Effect**: AVPlayer processes data and may request more
- **Error handling**: `finishLoading(with: error)` for failures

This implementation enables **progressive caching** where AVPlayer streams video while simultaneously building a local cache for future playback!
