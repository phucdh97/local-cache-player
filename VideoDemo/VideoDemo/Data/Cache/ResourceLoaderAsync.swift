//
//  ResourceLoaderAsync.swift
//  VideoDemo
//
//  Async coordinator for AVAssetResourceLoader using FileHandleAssetRepository
//  Production implementation for large video files
//

import AVFoundation
import Foundation

/// Async resource loader using FileHandle-based storage
/// Bridges AVAssetResourceLoaderDelegate (sync callbacks) with async repository operations
class ResourceLoaderAsync: NSObject {
    
    // MARK: - Properties
    
    /// Dedicated serial queue for AVAssetResourceLoaderDelegate callbacks
    let loaderQueue = DispatchQueue(label: "com.videodemo.resourceLoaderAsync.queue")
    
    /// Track active requests
    private var requests: [AVAssetResourceLoadingRequest: ResourceLoaderRequestAsync] = [:]
    
    private let cacheKey: String
    private let originalURL: URL
    private let cachingConfig: CachingConfiguration
    private let repository: FileHandleAssetRepository
    
    // MARK: - Initialization
    
    init(asset: CachingAVURLAssetAsync, cachingConfig: CachingConfiguration = .default, repository: FileHandleAssetRepository) {
        self.cacheKey = asset.cacheKey
        self.originalURL = asset.originalURL
        self.cachingConfig = cachingConfig
        self.repository = repository
        super.init()
        print("🏗️ [Async] ResourceLoaderAsync initialized for \(originalURL.lastPathComponent)")
    }
    
    deinit {
        print("♻️ [Async] ResourceLoaderAsync deinit for \(originalURL.lastPathComponent)")
        print("♻️ [Async]   Cancelling \(requests.count) active request(s)")
        requests.forEach { $0.value.cancel() }
        print("♻️ [Async] ResourceLoaderAsync deinit completed")
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension ResourceLoaderAsync: AVAssetResourceLoaderDelegate {
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let type = ResourceLoaderAsync.resourceLoaderRequestType(loadingRequest)
        
        // Bridge to async world: check cache and start request
        Task {
            await handleLoadingRequest(loadingRequest, type: type)
        }
        
        return true
    }
    
    private func handleLoadingRequest(_ loadingRequest: AVAssetResourceLoadingRequest, type: ResourceLoaderRequestAsync.RequestType) async {
        
        // ═══════════════════════════════════════════
        // CACHE CHECK FIRST (Cache-first strategy)
        // ═══════════════════════════════════════════
        
        if let assetData = await repository.retrieveAssetData() {
            if type == .contentInformation {
                // Content info is cached - return immediately
                loadingRequest.contentInformationRequest?.contentLength = assetData.contentInformation.contentLength
                loadingRequest.contentInformationRequest?.contentType = assetData.contentInformation.contentType
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = assetData.contentInformation.isByteRangeAccessSupported
                loadingRequest.finishLoading()
                print("✅ [Async] Content info from cache (length: \(formatBytes(assetData.contentInformation.contentLength)))")
                return
            } else {
                // Data request - check if we have cached ranges
                let range = ResourceLoaderAsync.resourceLoaderRequestRange(type, loadingRequest)
                
                // Calculate requested length
                let requestedLength: Int
                switch range.end {
                case .requestTo(let rangeEnd):
                    requestedLength = Int(rangeEnd - range.start)
                case .requestToEnd:
                    requestedLength = Int(assetData.contentInformation.contentLength - range.start)
                }
                
                let rangeEnd = range.start + Int64(requestedLength)
                print("🔍 [Async] Data request: range=\(range.start)-\(rangeEnd) (\(formatBytes(range.start))-\(formatBytes(rangeEnd)))")
                
                // Check if full range is cached
                if await repository.isRangeCached(offset: range.start, length: requestedLength) {
                    if let data = await repository.retrieveDataInRange(offset: range.start, length: requestedLength) {
                        loadingRequest.dataRequest?.respond(with: data)
                        loadingRequest.finishLoading()
                        print("✅ [Async] Full range from cache: \(formatBytes(data.count)) at \(range.start)")
                        return
                    }
                }
                
                // Check for partial cache coverage
                if let partialData = await repository.retrievePartialData(offset: range.start, length: requestedLength) {
                    if partialData.count > 0 {
                        loadingRequest.dataRequest?.respond(with: partialData)
                        print("⚡️ [Async] Partial range from cache: \(formatBytes(partialData.count)) at \(range.start), continuing to network")
                        // DON'T finishLoading() - continue to network
                    }
                }
            }
        }
        
        // ═══════════════════════════════════════════
        // START NETWORK REQUEST (Cache miss or partial hit)
        // ═══════════════════════════════════════════
        
        let range = ResourceLoaderAsync.resourceLoaderRequestRange(type, loadingRequest)
        let resourceLoaderRequest = ResourceLoaderRequestAsync(
            originalURL: originalURL,
            type: type,
            loaderQueue: loaderQueue,  // No longer used by actor
            assetDataManager: repository,
            cachingConfig: cachingConfig
        )
        resourceLoaderRequest.delegate = self
        
        // Store request and start (actor methods are async)
        await MainActor.run {
            requests[loadingRequest]?.cancel()  // Cancel any existing
            requests[loadingRequest] = resourceLoaderRequest
        }
        
        // Start network request (actor method)
        await resourceLoaderRequest.start(requestRange: range)
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let resourceLoaderRequest = requests[loadingRequest] else {
            print("❌ [Async] AVPlayer cancelled unknown request")
            return
        }
        
        print("❌ [Async] AVPlayer didCancel callback")
        
        // Actor method must be called async
        Task {
            await resourceLoaderRequest.cancel()
        }
        
        requests.removeValue(forKey: loadingRequest)
    }
}

// MARK: - ResourceLoaderRequestAsyncDelegate

extension ResourceLoaderAsync: ResourceLoaderRequestAsyncDelegate {
    
    func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ result: Result<AssetDataContentInformation, Error>) {
        guard let loadingRequest = requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        switch result {
        case .success(let contentInformation):
            loadingRequest.contentInformationRequest?.contentType = contentInformation.contentType
            loadingRequest.contentInformationRequest?.contentLength = contentInformation.contentLength
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = contentInformation.isByteRangeAccessSupported
            loadingRequest.finishLoading()
            
        case .failure(let error):
            loadingRequest.finishLoading(with: error)
        }
    }
    
    func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ data: Data) {
        guard let loadingRequest = requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        // Stream data to AVPlayer immediately
        loadingRequest.dataRequest?.respond(with: data)
    }
    
    func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ error: Error?, _ downloadedData: Data) {
        guard let loadingRequest = requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        loadingRequest.finishLoading(with: error)
        requests.removeValue(forKey: loadingRequest)
    }
}

// MARK: - Helper Methods

extension ResourceLoaderAsync {
    
    static func resourceLoaderRequestType(_ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequestAsync.RequestType {
        if let _ = loadingRequest.contentInformationRequest {
            return .contentInformation
        } else {
            return .dataRequest
        }
    }
    
    static func resourceLoaderRequestRange(_ type: ResourceLoaderRequestAsync.RequestType, _ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequestAsync.RequestRange {
        if type == .contentInformation {
            return ResourceLoaderRequestAsync.RequestRange(start: 0, end: .requestTo(1))
        } else {
            if loadingRequest.dataRequest?.requestsAllDataToEndOfResource == true {
                let lowerBound = loadingRequest.dataRequest?.currentOffset ?? 0
                return ResourceLoaderRequestAsync.RequestRange(start: lowerBound, end: .requestToEnd)
            } else {
                let lowerBound = loadingRequest.dataRequest?.currentOffset ?? 0
                let length = Int64(loadingRequest.dataRequest?.requestedLength ?? 1)
                let upperBound = lowerBound + length
                return ResourceLoaderRequestAsync.RequestRange(start: lowerBound, end: .requestTo(upperBound))
            }
        }
    }
}
