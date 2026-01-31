//
//  ResourceLoaderRequest.swift
//  VideoDemo
//
//  Individual request handler for AVAssetResourceLoadingRequest
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import Foundation
import CoreServices

protocol ResourceLoaderRequestDelegate: AnyObject {
    func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequest, _ data: Data)
    func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest, _ error: Error?, _ downloadedData: Data)
    func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequest, _ result: Result<AssetDataContentInformation, Error>)
}

class ResourceLoaderRequest: NSObject, URLSessionDataDelegate {
    
    // MARK: - Types
    
    struct RequestRange {
        var start: Int64
        var end: RequestRangeEnd
        
        enum RequestRangeEnd {
            case requestTo(Int64)
            case requestToEnd
        }
    }
    
    enum RequestType {
        case contentInformation
        case dataRequest
    }
    
    struct ResponseUnExpectedError: Error { }
    
    // MARK: - Properties
    
    private let loaderQueue: DispatchQueue
    
    let originalURL: URL
    let type: RequestType
    
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var assetDataManager: AssetDataRepository?
    
    // Caching configuration (injected dependency)
    private let cachingConfig: CachingConfiguration
    
    private(set) var requestRange: RequestRange?
    private(set) var response: URLResponse?
    private(set) var downloadedData: Data = Data()
    
    // INCREMENTAL CACHING: Track save progress
    private var lastSavedOffset: Int = 0
    
    private(set) var isCancelled: Bool = false {
        didSet {
            if isCancelled {
                print("🔴 isCancelled didSet triggered for \(self.originalURL.lastPathComponent)")
                print("🔴 Calling dataTask.cancel() and session.invalidateAndCancel()")
                self.dataTask?.cancel()
                self.session?.invalidateAndCancel()
                print("🔴 URLSession cancellation triggered, waiting for didCompleteWithError callback...")
            }
        }
    }
    
    private(set) var isFinished: Bool = false {
        didSet {
            if isFinished {
                self.session?.finishTasksAndInvalidate()
            }
        }
    }
    
    weak var delegate: ResourceLoaderRequestDelegate?
    
    // MARK: - Initialization
    
    init(originalURL: URL, type: RequestType, loaderQueue: DispatchQueue, assetDataManager: AssetDataRepository?, cachingConfig: CachingConfiguration = .default) {
        self.originalURL = originalURL
        self.type = type
        self.loaderQueue = loaderQueue
        self.assetDataManager = assetDataManager
        self.cachingConfig = cachingConfig
        super.init()
    }
    
    // MARK: - Request Management
    
    func start(requestRange: RequestRange) {
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
                end = String(rangeEnd)
            case .requestToEnd:
                end = ""
            }
            
            let rangeHeader = "bytes=\(start)-\(end)"
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            
            print("🌐 Request START: \(rangeHeader) for \(self.originalURL.lastPathComponent), type: \(self.type == .dataRequest ? "data" : "info")")
            
            // 3. Create URLSession with self as delegate
            let session = URLSession(configuration: .default,
                                    delegate: self,
                                    delegateQueue: nil)
            self.session = session
            
            // 4. Create and start data task
            let dataTask = session.dataTask(with: request)
            self.dataTask = dataTask
            dataTask.resume()
            print("🌐 URLSession task started for \(self.originalURL.lastPathComponent)")
        }
    }
    
    func cancel() {
        print("🚫 cancel() called for \(self.originalURL.lastPathComponent), accumulated: \(formatBytes(self.downloadedData.count)), type: \(self.type == .dataRequest ? "data" : "info")")
        
        // INCREMENTAL CACHING: Save unsaved data before cancelling
        if cachingConfig.isIncrementalCachingEnabled && self.type == .dataRequest {
            saveIncrementalChunkIfNeeded(force: true)
        }
        
        self.isCancelled = true
        print("🚫 cancel() setting isCancelled=true, will trigger dataTask.cancel()")
    }
    
    // MARK: - Incremental Caching
    
    /// Save accumulated data incrementally using injected configuration
    /// - Parameter force: If true, saves any unsaved data regardless of threshold
    private func saveIncrementalChunkIfNeeded(force: Bool = false) {
        guard let requestStartOffset = self.requestRange?.start else { return }
        
        let unsavedBytes = self.downloadedData.count - self.lastSavedOffset
        
        // Check threshold from injected config (not global singleton!)
        let shouldSave = force ? (unsavedBytes > 0) : (unsavedBytes >= cachingConfig.incrementalSaveThreshold)
        
        guard shouldSave else { return }
        
        let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
        guard unsavedData.count > 0 else { return }
        
        let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
        
        print("💾 Incremental save: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset))) (total: \(formatBytes(self.downloadedData.count)))")
        
        self.assetDataManager?.saveDownloadedData(Data(unsavedData), offset: actualOffset)
        self.lastSavedOffset = self.downloadedData.count
        
        print("✅ Incremental save completed, lastSavedOffset: \(formatBytes(self.lastSavedOffset))")
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.type == .dataRequest else {
            return
        }
        
        // ALWAYS dispatch back to serial queue for thread safety
        self.loaderQueue.async {
            // Check if we're already cancelled
            if self.isCancelled {
                print("⚠️ Received chunk AFTER cancel for \(self.originalURL.lastPathComponent), ignoring")
                return
            }
            
            // 1. Immediately forward to AVPlayer (streaming)
            self.delegate?.dataRequestDidReceive(self, data)
            
            // 2. Accumulate for caching
            self.downloadedData.append(data)
            
            print("📥 Received chunk: \(formatBytes(data.count)), accumulated: \(formatBytes(self.downloadedData.count)) for \(self.originalURL.lastPathComponent)")
            
            // 3. INCREMENTAL CACHING: Check threshold from config
            if self.cachingConfig.isIncrementalCachingEnabled {
                self.saveIncrementalChunkIfNeeded(force: false)
            }
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("⏹️ didCompleteWithError called for \(self.originalURL.lastPathComponent)")
        print("⏹️   Error: \(error?.localizedDescription ?? "nil (success)")")
        print("⏹️   Type: \(self.type == .dataRequest ? "data" : "info"), Downloaded: \(formatBytes(self.downloadedData.count))")
        print("⏹️   isCancelled: \(self.isCancelled), isFinished: \(self.isFinished)")
        
        self.isFinished = true
        
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
                    contentInformation.contentLength = bytes
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
                } else {
                    contentInformation.isByteRangeAccessSupported = false
                }
                
                // SAVE TO CACHE
                self.assetDataManager?.saveContentInformation(contentInformation)
                
                print("📋 Content info: \(formatBytes(contentInformation.contentLength))")
                
                // Notify delegate
                self.delegate?.contentInformationDidComplete(self, .success(contentInformation))
                
            } else {
                // ═══════════════════════════════════════════
                // DATA REQUEST COMPLETION
                // ═══════════════════════════════════════════
                
                print("💿 Data request completion handler")
                print("💿   Request range: \(self.requestRange?.start ?? -1) to \(String(describing: self.requestRange?.end))")
                print("💿   Downloaded data size: \(formatBytes(self.downloadedData.count))")
                print("💿   Already saved: \(formatBytes(self.lastSavedOffset))")
                
                // SAVE TO CACHE - Only save unsaved portion if incremental caching is enabled
                if let offset = self.requestRange?.start, self.downloadedData.count > 0 {
                    if self.cachingConfig.isIncrementalCachingEnabled {
                        // Incremental caching: Only save remainder (unsaved portion)
                        let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
                        if unsavedData.count > 0 {
                            let actualOffset = Int(offset) + self.lastSavedOffset
                            print("💾 Saving remainder: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset))) for \(self.originalURL.lastPathComponent)")
                            self.assetDataManager?.saveDownloadedData(Data(unsavedData), offset: actualOffset)
                            print("✅ Remainder saved")
                        } else {
                            print("✅ All data already saved incrementally (nothing to save)")
                        }
                    } else {
                        // Original behavior: Save everything at once
                        print("💾 Saving \(formatBytes(self.downloadedData.count)) at offset \(offset) for \(self.originalURL.lastPathComponent)")
                        print("💾   This includes ALL accumulated data from this request")
                        self.assetDataManager?.saveDownloadedData(self.downloadedData, offset: Int(offset))
                        print("✅ Save completed, notifying delegate")
                    }
                } else if self.downloadedData.count == 0 {
                    print("⚠️ No data to save for \(self.originalURL.lastPathComponent)")
                }
                
                // Notify delegate
                self.delegate?.dataRequestDidComplete(self, error, self.downloadedData)
                print("💿 Data request completion handler finished")
            }
        }
    }
}
