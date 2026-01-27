//
//  ResourceLoader.swift
//  VideoDemo
//
//  Main coordinator for AVAssetResourceLoader with dictionary-based request tracking
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import AVFoundation
import Foundation

class ResourceLoader: NSObject {
    
    // MARK: - Properties
    
    /// Dedicated serial queue for thread-safe coordination
    /// NOT main queue - follows reference implementation
    let loaderQueue = DispatchQueue(label: "com.videodemo.resourceLoader.queue")
    
    /// Dictionary-based request tracking
    /// Key: AVAssetResourceLoadingRequest from AVPlayer
    /// Value: Our ResourceLoaderRequest handling the network operation
    private var requests: [AVAssetResourceLoadingRequest: ResourceLoaderRequest] = [:]
    
    private let cacheKey: String
    private let originalURL: URL
    
    // MARK: - Initialization
    
    init(asset: CachingAVURLAsset) {
        self.cacheKey = asset.cacheKey
        self.originalURL = asset.originalURL
        super.init()
    }
    
    deinit {
        // Cancel all active requests on cleanup
        self.requests.forEach { (request) in
            request.value.cancel()
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

extension ResourceLoader: AVAssetResourceLoaderDelegate {
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        
        let type = ResourceLoader.resourceLoaderRequestType(loadingRequest)
        let assetDataManager = PINCacheAssetDataManager(cacheKey: self.cacheKey)
        
        // ═══════════════════════════════════════════
        // CACHE CHECK FIRST (Cache-first strategy)
        // ═══════════════════════════════════════════
        
        if let assetData = assetDataManager.retrieveAssetData() {
            if type == .contentInformation {
                // Content info is cached - return immediately
                loadingRequest.contentInformationRequest?.contentLength = assetData.contentInformation.contentLength
                loadingRequest.contentInformationRequest?.contentType = assetData.contentInformation.contentType
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = assetData.contentInformation.isByteRangeAccessSupported
                loadingRequest.finishLoading()
                print("✅ Content info from cache")
                return true
            } else {
                // Data request - check if we have enough cached data
                let range = ResourceLoader.resourceLoaderRequestRange(type, loadingRequest)
                
                if assetData.mediaData.count > 0 {
                    let end: Int64
                    switch range.end {
                    case .requestTo(let rangeEnd):
                        end = rangeEnd
                    case .requestToEnd:
                        end = assetData.contentInformation.contentLength
                    }
                    
                    // Full cache hit - serve from cache
                    if assetData.mediaData.count >= end {
                        let subData = assetData.mediaData.subdata(in: Int(range.start)..<Int(end))
                        loadingRequest.dataRequest?.respond(with: subData)
                        loadingRequest.finishLoading()
                        print("✅ Full data from cache: \(subData.count) bytes")
                        return true
                    }
                    // Partial cache hit - serve what we have, continue to network
                    else if range.start <= assetData.mediaData.count {
                        let subEnd = (assetData.mediaData.count > end) ? Int(end) : assetData.mediaData.count
                        let subData = assetData.mediaData.subdata(in: Int(range.start)..<subEnd)
                        loadingRequest.dataRequest?.respond(with: subData)
                        print("⚡️ Partial data from cache: \(subData.count) bytes, continuing to network...")
                        // DON'T finishLoading() - continue to network request
                    }
                }
            }
        }
        
        // ═══════════════════════════════════════════
        // START NETWORK REQUEST (Cache miss or partial hit)
        // ═══════════════════════════════════════════
        
        let range = ResourceLoader.resourceLoaderRequestRange(type, loadingRequest)
        let resourceLoaderRequest = ResourceLoaderRequest(
            originalURL: self.originalURL,
            type: type,
            loaderQueue: self.loaderQueue,
            assetDataManager: assetDataManager
        )
        resourceLoaderRequest.delegate = self
        
        // Cancel any existing request for this loadingRequest
        self.requests[loadingRequest]?.cancel()
        
        // Store in dictionary for tracking
        self.requests[loadingRequest] = resourceLoaderRequest
        
        // Start network request
        resourceLoaderRequest.start(requestRange: range)
        
        return true
    }
    
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let resourceLoaderRequest = self.requests[loadingRequest] else {
            return
        }
        
        print("❌ Request cancelled")
        resourceLoaderRequest.cancel()
        requests.removeValue(forKey: loadingRequest)
    }
}

// MARK: - ResourceLoaderRequestDelegate

extension ResourceLoader: ResourceLoaderRequestDelegate {
    
    func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest, _ result: Result<AssetDataContentInformation, Error>) {
        // Find the original AVPlayer loading request
        guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        switch result {
        case .success(let contentInformation):
            // Populate AVPlayer's content information request
            loadingRequest.contentInformationRequest?.contentType = contentInformation.contentType
            loadingRequest.contentInformationRequest?.contentLength = contentInformation.contentLength
            loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = contentInformation.isByteRangeAccessSupported
            
            // Tell AVPlayer we're done
            loadingRequest.finishLoading()
            
        case .failure(let error):
            // Tell AVPlayer we failed
            loadingRequest.finishLoading(with: error)
        }
    }
    
    func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequest, _ data: Data) {
        // Find the original AVPlayer loading request
        guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        // Send data to AVPlayer IMMEDIATELY (streaming)
        loadingRequest.dataRequest?.respond(with: data)
    }
    
    func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest, _ error: Error?, _ downloadedData: Data) {
        // Find the original AVPlayer loading request
        guard let loadingRequest = self.requests.first(where: { $0.value == resourceLoaderRequest })?.key else {
            return
        }
        
        // Tell AVPlayer we're done (with optional error)
        loadingRequest.finishLoading(with: error)
        
        // Clean up - remove from active requests
        requests.removeValue(forKey: loadingRequest)
    }
}

// MARK: - Helper Methods

extension ResourceLoader {
    
    static func resourceLoaderRequestType(_ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequest.RequestType {
        if let _ = loadingRequest.contentInformationRequest {
            return .contentInformation
        } else {
            return .dataRequest
        }
    }
    
    static func resourceLoaderRequestRange(_ type: ResourceLoaderRequest.RequestType, _ loadingRequest: AVAssetResourceLoadingRequest) -> ResourceLoaderRequest.RequestRange {
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
}
