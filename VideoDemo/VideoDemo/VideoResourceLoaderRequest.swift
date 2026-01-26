//
//  VideoResourceLoaderRequest.swift
//  VideoDemo
//
//  Handles individual resource loading requests with dedicated network tasks
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher (ResourceLoaderRequest.swift)
//  Adapted for Actor-based VideoCacheManager
//

import Foundation
import AVFoundation

/// Manages a single AVAssetResourceLoadingRequest with its own URLSession task
/// Each request gets independent network connection for optimal seeking performance
class VideoResourceLoaderRequest: NSObject {

    // MARK: - Properties

    private let originalURL: URL
    private let loadingRequest: AVAssetResourceLoadingRequest
    private let cacheManager = VideoCacheManager.shared
    private let loaderQueue: DispatchQueue  // Shared queue for thread-safe coordination

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var response: HTTPURLResponse?

    private var downloadOffset: Int64 = 0
    private var expectedContentLength: Int64 = 0

    // Thread-safe chunk storage for in-flight data
    private let chunksQueue = DispatchQueue(label: "com.videocache.request.chunks", qos: .userInitiated)
    private var receivedChunks: [(offset: Int64, data: Data)] = []
    private let maxRecentChunks = 20 // Keep last 20 chunks (~5MB)

    private var isCancelled = false

    // MARK: - Initialization

    init(originalURL: URL, loadingRequest: AVAssetResourceLoadingRequest, loaderQueue: DispatchQueue) {
        self.originalURL = originalURL
        self.loadingRequest = loadingRequest
        self.loaderQueue = loaderQueue
        super.init()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Create dedicated URLSession for this request
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public Methods

    /// Start processing the loading request
    /// First tries cache, then falls back to network
    func start() {
        guard !isCancelled else { return }

        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        let length = loadingRequest.dataRequest?.requestedLength ?? 0
        print("📥 VideoResourceLoaderRequest.start() - offset=\(offset), length=\(length)")

        // Try to fulfill from cache first
        Task {
            if await tryFulfillFromCache() {
                print("✅ Request fulfilled from cache")
                return
            }

            // Start network request if cache miss
            startNetworkRequest()
        }
    }

    /// Cancel this request and cleanup resources
    func cancel() {
        guard !isCancelled else { return }
        
        isCancelled = true
        dataTask?.cancel()
        session?.invalidateAndCancel()

        chunksQueue.async { [weak self] in
            self?.receivedChunks.removeAll()
        }

        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        print("❌ VideoResourceLoaderRequest cancelled for offset: \(offset)")
    }

    // MARK: - Private Methods

    /// Try to fulfill request from cache
    /// Returns true if fully fulfilled, false if needs network
    private func tryFulfillFromCache() async -> Bool {
        // Fill content information if requested
        if let infoRequest = loadingRequest.contentInformationRequest {
            await fillInfoRequest(infoRequest)
        }

        // Try to fill data request from cache
        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let offset = dataRequest.currentOffset
        let length = dataRequest.requestedLength - Int(offset - dataRequest.requestedOffset)

        // Check if range is cached
        if await cacheManager.isRangeCached(for: originalURL, offset: offset, length: Int64(length)) {
            if let cachedData = cacheManager.cachedData(for: originalURL, offset: offset, length: length) {
                dataRequest.respond(with: cachedData)
                loadingRequest.finishLoading()
                print("✅ Fulfilled from cache: offset=\(offset), length=\(cachedData.count)")
                return true
            }
        }

        return false
    }

    /// Fill content information request from cache or wait for network response
    private func fillInfoRequest(_ infoRequest: AVAssetResourceLoadingContentInformationRequest) async {
        // Try to get from cache metadata
        if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
           let contentLength = metadata.contentLength {
            infoRequest.contentLength = contentLength
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentType = metadata.contentType ?? "video/mp4"
            print("📋 Content info from cache: length=\(contentLength)")
            return
        }

        // Will be filled when network response arrives
        print("⏳ Waiting for network response to fill content info")
    }

    /// Start network request with Range header
    private func startNetworkRequest() {
        guard !isCancelled else { return }

        let dataRequest = loadingRequest.dataRequest
        let requestedOffset = dataRequest?.requestedOffset ?? 0
        let requestedLength = dataRequest?.requestedLength ?? 0

        // Check for partial cache to optimize download range
        let cachedSize = cacheManager.getCachedDataSize(for: originalURL)
        downloadOffset = max(requestedOffset, cachedSize)

        // Dispatch network setup on loaderQueue (like resourceLoaderDemo pattern)
        loaderQueue.async { [weak self] in
            guard let self = self else { return }
            
            var request = URLRequest(url: self.originalURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData

            // Set Range header for efficient partial download
            if requestedLength > 0 {
                let rangeEnd = requestedOffset + Int64(requestedLength) - 1
                request.setValue("bytes=\(self.downloadOffset)-\(rangeEnd)", forHTTPHeaderField: "Range")
                print("📍 Starting request: Range=bytes=\(self.downloadOffset)-\(rangeEnd)")
            } else {
                // Request to end
                if self.downloadOffset > 0 {
                    request.setValue("bytes=\(self.downloadOffset)-", forHTTPHeaderField: "Range")
                    print("📍 Starting request: Range=bytes=\(self.downloadOffset)-")
                } else {
                    print("📍 Starting full request (no Range header)")
                }
            }

            self.dataTask = self.session?.dataTask(with: request)
            self.dataTask?.resume()
        }
    }

    /// Process loading request by serving data from cache hierarchy
    /// Order: Memory cache (fastest) → Disk cache → Wait for network
    private func processLoadingRequest() {
        guard let dataRequest = loadingRequest.dataRequest else { return }

        let requestedOffset = dataRequest.requestedOffset
        let currentOffset = dataRequest.currentOffset
        let requestedLength = dataRequest.requestedLength
        let availableLength = requestedLength - Int(currentOffset - requestedOffset)

        // 1️⃣ FASTEST: Try memory cache first (receivedChunks - last ~5MB)
        var foundInMemory = false
        chunksQueue.sync {
            for chunk in receivedChunks {
                let chunkEnd = chunk.offset + Int64(chunk.data.count)

                if currentOffset >= chunk.offset && currentOffset < chunkEnd {
                    let chunkOffset = Int(currentOffset - chunk.offset)
                    let availableInChunk = min(availableLength, chunk.data.count - chunkOffset)

                    if chunkOffset >= 0 && chunkOffset < chunk.data.count {
                        let data = chunk.data.subdata(in: chunkOffset..<(chunkOffset + availableInChunk))
                        dataRequest.respond(with: data)
                        print("✅ Responded from MEMORY: \(data.count) bytes at offset \(currentOffset)")

                        // Check if request is complete
                        if dataRequest.currentOffset >= requestedOffset + Int64(requestedLength) {
                            loadingRequest.finishLoading()
                            print("✅ Request completed at offset \(dataRequest.currentOffset)")
                        }

                        foundInMemory = true
                        return
                    }
                }
            }
        }
        
        if foundInMemory { return }
        
        // 2️⃣ FALLBACK: Try disk cache (for data not in memory, e.g., from previous requests)
        if let cachedData = cacheManager.cachedData(for: originalURL, 
                                                     offset: currentOffset, 
                                                     length: availableLength) {
            dataRequest.respond(with: cachedData)
            print("✅ Responded from DISK cache: \(cachedData.count) bytes at offset \(currentOffset)")
            
            // Check if request is complete
            if dataRequest.currentOffset >= requestedOffset + Int64(requestedLength) {
                loadingRequest.finishLoading()
                print("✅ Request completed at offset \(dataRequest.currentOffset)")
            }
            return
        }
        
        // 3️⃣ Data not available yet - wait for network
        print("⏳ Waiting for network data at offset \(currentOffset)")
    }

    deinit {
        cancel()
        print("♻️ VideoResourceLoaderRequest deinitialized")
    }
}

// MARK: - URLSessionDataDelegate

extension VideoResourceLoaderRequest: URLSessionDataDelegate {

    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive response: URLResponse,
                   completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        self.response = response as? HTTPURLResponse

        if let httpResponse = response as? HTTPURLResponse {
            print("📡 Received response: status=\(httpResponse.statusCode)")

            // Fill content information if needed
            if let infoRequest = loadingRequest.contentInformationRequest {
                let contentLength: Int64
                
                if httpResponse.statusCode == 206 {
                    // Partial content - parse Content-Range header
                    contentLength = parseContentRangeTotal(httpResponse)
                } else {
                    // Full content
                    contentLength = httpResponse.expectedContentLength
                }

                expectedContentLength = contentLength
                infoRequest.contentLength = contentLength
                infoRequest.isByteRangeAccessSupported = true
                infoRequest.contentType = httpResponse.mimeType ?? "video/mp4"

                print("📋 Content info: length=\(contentLength), type=\(infoRequest.contentType ?? "unknown")")

                // Save metadata to cache
                Task {
                    await cacheManager.saveCacheMetadata(
                        for: originalURL,
                        contentLength: contentLength,
                        contentType: infoRequest.contentType
                    )
                }
            }
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive data: Data) {

        guard !isCancelled else { return }

        let currentPosition = downloadOffset
        downloadOffset += Int64(data.count)

        // Calculate progress
        var percentageStr = ""
        if expectedContentLength > 0 {
            let percentage = (Double(downloadOffset) / Double(expectedContentLength)) * 100.0
            percentageStr = String(format: " (%.1f%%)", percentage)
        }

        print("💾 Received chunk: \(data.count) bytes at offset \(currentPosition)\(percentageStr)")

        // Store in recent chunks for fast access (on chunksQueue)
        chunksQueue.async { [weak self] in
            guard let self = self else { return }
            self.receivedChunks.append((offset: currentPosition, data: data))

            // Keep only recent chunks to prevent memory growth
            if self.receivedChunks.count > self.maxRecentChunks {
                self.receivedChunks.removeFirst()
            }
        }

        // Cache to disk (synchronous, non-isolated)
        cacheManager.cacheChunk(data, for: originalURL, at: currentPosition)

        // Update cached ranges (async actor call)
        Task {
            await cacheManager.addCachedRange(for: originalURL, offset: currentPosition, length: Int64(data.count))
        }

        // Try to fulfill loading request with newly available data
        // Dispatch on loaderQueue to synchronize with other operations
        loaderQueue.async { [weak self] in
            self?.processLoadingRequest()
        }
    }

    func urlSession(_ session: URLSession,
                   task: URLSessionTask,
                   didCompleteWithError error: Error?) {

        if let error = error {
            print("❌ Request error: \(error.localizedDescription)")
            
            // Dispatch on loaderQueue to synchronize with other operations
            loaderQueue.async { [weak self] in
                guard let self = self else { return }
                self.loadingRequest.finishLoading(with: error)
            }
        } else {
            print("✅ Download complete: \(downloadOffset) bytes")

            // Mark as fully cached if we downloaded everything
            Task {
                if expectedContentLength > 0 && downloadOffset >= expectedContentLength {
                    await cacheManager.markAsFullyCached(for: originalURL, size: downloadOffset)
                }
            }

            // Try final fulfillment on loaderQueue
            loaderQueue.async { [weak self] in
                self?.processLoadingRequest()
            }
        }

        // Cleanup chunks
        chunksQueue.async { [weak self] in
            self?.receivedChunks.removeAll()
        }
    }

    /// Parse total content length from Content-Range header
    /// Format: "bytes 0-999/1000" or "bytes 500-999/1000"
    private func parseContentRangeTotal(_ response: HTTPURLResponse) -> Int64 {
        if let contentRange = response.allHeaderFields["Content-Range"] as? String {
            print("📍 Content-Range: \(contentRange)")
            
            // Parse "bytes 0-999/1000" -> extract "1000"
            if let totalSizeStr = contentRange.split(separator: "/").last {
                if let totalSize = Int64(String(totalSizeStr)) {
                    return totalSize
                }
            }
        }
        
        // Fallback to expectedContentLength
        return response.expectedContentLength
    }
}
