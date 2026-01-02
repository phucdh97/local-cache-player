//
//  VideoResourceLoaderDelegate.swift
//  VideoDemo
//
//  Handles AVAssetResourceLoader requests for video caching with progressive download
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import AVFoundation

class VideoResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    
    private var loadingRequests: [AVAssetResourceLoadingRequest] = []
    private var session: URLSession!
    private var downloadTask: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private let originalURL: URL
    private let cacheManager = VideoCacheManager.shared
    
    private var downloadOffset: Int64 = 0
    private var expectedContentLength: Int64 = 0
    
    // Simple in-memory buffer for recent chunks only (no trimming!)
    // Thread-safe access via Serial DispatchQueue (following blog's pattern)
    private let recentChunksQueue = DispatchQueue(label: "com.videocache.recentchunks", qos: .userInitiated)
    private var recentChunks: [(offset: Int64, data: Data)] = []
    private let maxRecentChunks = 20 // Keep last 20 chunks (~5MB)
    
    init(url: URL) {
        self.originalURL = url
        super.init()
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        // Use delegate-based session for progressive download
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    
    // MARK: - AVAssetResourceLoaderDelegate
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let offset = loadingRequest.dataRequest?.requestedOffset ?? 0
        let length = loadingRequest.dataRequest?.requestedLength ?? 0
        print("📥 Loading request: offset=\(offset), length=\(length)")
        
        // Check if this range is already cached (async actor call)
        Task {
            if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
               await cacheManager.isRangeCached(for: originalURL, offset: offset, length: Int64(length)) {
                print("✅ Range is cached, serving from cache")
                await self.handleLoadingRequest(loadingRequest)
                return
            }
            
            // Add to pending requests
            self.loadingRequests.append(loadingRequest)
            
            // Try to fulfill with already downloaded data
            await self.processLoadingRequests()
            
            // Start download if not already downloading
            if self.downloadTask == nil {
                self.startProgressiveDownload()
            }
        }
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                       didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        print("❌ Loading request cancelled")
        loadingRequests.removeAll { $0 == loadingRequest }
    }
    
    // MARK: - Download Management
    
    private func startProgressiveDownload() {
        // Check if video is fully cached - no need to download (async actor call)
        Task {
            if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
               metadata.isFullyCached {
                print("✅ Video fully cached, no download needed")
                return
            }
            
            // Check if we have partial cache to resume from (non-isolated call, synchronous)
            let cachedSize = cacheManager.getCachedDataSize(for: originalURL)
            self.downloadOffset = cachedSize
            
            // Clear recent chunks (using serial queue)
            self.recentChunksQueue.async {
                self.recentChunks.removeAll()
            }
            
            print("🌐 Starting progressive download from offset: \(self.downloadOffset)")
            
            var request = URLRequest(url: self.originalURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            
            // If we have partial data, request from where we left off
            if self.downloadOffset > 0 {
                request.setValue("bytes=\(self.downloadOffset)-", forHTTPHeaderField: "Range")
                print("📍 Resuming download from byte \(self.downloadOffset)")
            }
            
            self.downloadTask = self.session.dataTask(with: request)
            self.downloadTask?.resume()
        }
    }
    
    private func processLoadingRequests() async {
        var completedRequests: [AVAssetResourceLoadingRequest] = []
        
        for loadingRequest in loadingRequests {
            if await handleLoadingRequest(loadingRequest) {
                completedRequests.append(loadingRequest)
            }
        }
        
        // Remove completed requests
        for request in completedRequests {
            loadingRequests.removeAll { $0 == request }
        }
    }
    
    @discardableResult
    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest) async -> Bool {
        // Fill content information
        if let infoRequest = loadingRequest.contentInformationRequest {
            await fillInfoRequest(infoRequest)
        }
        
        // Fill data request
        if let dataRequest = loadingRequest.dataRequest {
            return fillDataRequest(dataRequest, loadingRequest: loadingRequest)
        }
        
        return false
    }
    
    private func fillInfoRequest(_ infoRequest: AVAssetResourceLoadingContentInformationRequest) async {
        // Try to get metadata from cache (async actor call)
        if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
           let contentLength = metadata.contentLength {
            infoRequest.contentLength = contentLength
            infoRequest.isByteRangeAccessSupported = true
            infoRequest.contentType = metadata.contentType ?? "video/mp4"
            print("📋 Content info from cache: length=\(contentLength)")
            return
        }
        
        // Use response from network
        if let response = response {
            let contentLength = response.expectedContentLength
            expectedContentLength = contentLength
            infoRequest.contentLength = contentLength
            infoRequest.isByteRangeAccessSupported = true
            
            if let contentType = response.mimeType {
                infoRequest.contentType = contentType
            } else {
                infoRequest.contentType = "video/mp4"
            }
            
            // Save metadata (async actor call)
            await cacheManager.saveCacheMetadata(for: originalURL, 
                                          contentLength: contentLength,
                                          contentType: infoRequest.contentType)
            
            print("📋 Content info from network: length=\(contentLength), type=\(infoRequest.contentType ?? "unknown")")
        }
    }
    
    private func fillDataRequest(_ dataRequest: AVAssetResourceLoadingDataRequest,
                                loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let requestedOffset = dataRequest.requestedOffset
        let requestedLength = dataRequest.requestedLength
        let currentOffset = dataRequest.currentOffset
        
        // Calculate actual offset to read from (handle seeking)
        let offset = currentOffset
        let availableLength = requestedLength - Int(offset - requestedOffset)
        
        print("🔍 fillDataRequest - requested:\(requestedOffset) current:\(currentOffset) length:\(availableLength)")
        
        // Try to get data from cache first (may return partial data)
        if let cachedData = cacheManager.cachedData(for: originalURL,
                                                    offset: offset,
                                                    length: availableLength) {
            dataRequest.respond(with: cachedData)
            print("✅ Responded with \(cachedData.count) bytes from cache at offset \(offset)")
            
            // Check if request is fully satisfied
            if dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength) {
                loadingRequest.finishLoading()
                print("✅ Request completed")
                return true
            }
            
            // Partial data provided, continue waiting for more
            print("⏳ Partial data served, waiting for more...")
            return false
        }
        
        // Try to get data from recent chunks (fast!)
        // Use synchronous queue access to get result immediately
        var foundData: Data? = nil
        var foundChunkEnd: Int64? = nil
        
        recentChunksQueue.sync {
            for chunk in recentChunks {
                let chunkEnd = chunk.offset + Int64(chunk.data.count)
                if offset >= chunk.offset && offset < chunkEnd {
                    let chunkOffset = Int(offset - chunk.offset)
                    let availableInChunk = min(availableLength, chunk.data.count - chunkOffset)
                    
                    if chunkOffset >= 0 && chunkOffset < chunk.data.count {
                        foundData = chunk.data.subdata(in: chunkOffset..<(chunkOffset + availableInChunk))
                        foundChunkEnd = chunkEnd
                        return
                    }
                }
            }
        }
        
        if let data = foundData {
            dataRequest.respond(with: data)
            print("✅ Responded with recent chunk: \(data.count) bytes at offset \(offset)")
            
            if dataRequest.currentOffset >= dataRequest.requestedOffset + Int64(dataRequest.requestedLength) {
                loadingRequest.finishLoading()
                return true
            }
            
            // Continue waiting for more
            return false
        }
        
        // Data not available yet
        print("⏳ Waiting for more data at offset \(offset)")
        return false
    }
    
    private func finishLoadingWithError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            for request in self.loadingRequests {
                request.finishLoading(with: error)
            }
            self.loadingRequests.removeAll()
        }
    }
    
    deinit {
        downloadTask?.cancel()
        session?.invalidateAndCancel()
        print("♻️ VideoResourceLoaderDelegate deinitialized")
    }
}

// MARK: - URLSessionDataDelegate

extension VideoResourceLoaderDelegate: URLSessionDataDelegate {
    
    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive response: URLResponse,
                   completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        
        self.response = response as? HTTPURLResponse
        
        if let httpResponse = response as? HTTPURLResponse {
            print("📡 Received response: status=\(httpResponse.statusCode)")
            
            // Get total content length from response
            if httpResponse.statusCode == 200 {
                // Full download
                expectedContentLength = httpResponse.expectedContentLength
            } else if httpResponse.statusCode == 206 {
                // Partial content - extract total size from Content-Range header
                if let contentRange = httpResponse.allHeaderFields["Content-Range"] as? String {
                    print("📍 Partial content: \(contentRange)")
                    
                    // Parse "bytes 19068105-158008373/158008374" to get total (158008374)
                    if let totalSizeStr = contentRange.split(separator: "/").last {
                        expectedContentLength = Int64(totalSizeStr) ?? httpResponse.expectedContentLength
                    }
                }
            }
            
            // Also try to get from metadata if available (async actor call)
            if expectedContentLength <= 0 {
                Task {
                    if let metadata = await cacheManager.getCacheMetadata(for: originalURL),
                       let contentLength = metadata.contentLength {
                        self.expectedContentLength = contentLength
                    }
                }
            }
            
            print("📊 Expected total size: \(expectedContentLength) bytes")
        }
        
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession,
                   dataTask: URLSessionDataTask,
                   didReceive data: Data) {
        
        // Calculate current absolute position
        let currentPosition = downloadOffset
        downloadOffset += Int64(data.count)
        
        // Calculate percentage if we know total size
        var percentageStr = ""
        if expectedContentLength > 0 {
            let percentage = (Double(downloadOffset) / Double(expectedContentLength)) * 100.0
            percentageStr = String(format: " (%.1f%%)", percentage)
        }
        
        print("💾 Received chunk: \(data.count) bytes at offset \(currentPosition), total downloaded: \(downloadOffset)\(percentageStr)")
        
        // Store in recent chunks for fast access (simple FIFO, no complex trimming)
        // Use async queue for write operation (doesn't block)
        recentChunksQueue.async { [weak self] in
            guard let self = self else { return }
            self.recentChunks.append((offset: currentPosition, data: data))
            // Simple: keep only last N chunks
            if self.recentChunks.count > self.maxRecentChunks {
                self.recentChunks.removeFirst()
            }
        }
        
        // Also cache to disk for persistence (progressive caching!) - synchronous, non-isolated
        cacheManager.cacheChunk(data, for: originalURL, at: currentPosition)
        
        // Update cached ranges (async actor call)
        Task {
            await cacheManager.addCachedRange(for: originalURL, offset: currentPosition, length: Int64(data.count))
        }
        
        // Try to fulfill pending requests with newly available data
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            Task {
                await self.processLoadingRequests()
            }
        }
    }
    
    func urlSession(_ session: URLSession,
                   task: URLSessionTask,
                   didCompleteWithError error: Error?) {
        
        if let error = error {
            print("❌ Download error: \(error.localizedDescription)")
            finishLoadingWithError(error)
        } else {
            print("✅ Download complete! Total size: \(downloadOffset) bytes")
            
            // Mark as fully cached (async actor call)
            Task {
                await cacheManager.markAsFullyCached(for: originalURL, size: downloadOffset)
            }
            
            // Process any remaining requests
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.processLoadingRequests()
                }
            }
        }
        
        downloadTask = nil
        
        // Clear recent chunks (using serial queue)
        recentChunksQueue.async { [weak self] in
            self?.recentChunks.removeAll()
        }
    }
}

