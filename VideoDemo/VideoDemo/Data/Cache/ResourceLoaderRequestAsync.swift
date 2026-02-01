//
//  ResourceLoaderRequestAsync.swift
//  VideoDemo
//
//  Async version of ResourceLoaderRequest for production use with FileHandle
//  Bridges callback-based URLSession with async/await FileHandle storage
//

import Foundation
import CoreServices

/// Async resource loader request handler
/// Handles network requests and saves to async FileHandle repository
@available(iOS 13.0, *)
class ResourceLoaderRequestAsync: NSObject, URLSessionDataDelegate {
    
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
    private let assetDataManager: FileHandleAssetRepository
    
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
                self.dataTask?.cancel()
                self.session?.invalidateAndCancel()
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
    
    weak var delegate: ResourceLoaderRequestAsyncDelegate?
    
    // MARK: - Initialization
    
    init(originalURL: URL,
         type: RequestType,
         loaderQueue: DispatchQueue,
         assetDataManager: FileHandleAssetRepository,
         cachingConfig: CachingConfiguration = .default) {
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
        
        self.loaderQueue.async { [weak self] in
            guard let self = self else { return }
            
            var request = URLRequest(url: self.originalURL)
            self.requestRange = requestRange
            
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
            
            print("🌐 [Async] Request START: \(rangeHeader) for \(self.originalURL.lastPathComponent)")
            
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            
            let dataTask = session.dataTask(with: request)
            self.dataTask = dataTask
            dataTask.resume()
        }
    }
    
    func cancel() {
        print("🚫 [Async] cancel() called, accumulated: \(formatBytes(self.downloadedData.count))")
        
        // Save unsaved data before cancelling
        if cachingConfig.isIncrementalCachingEnabled && self.type == .dataRequest {
            Task {
                await saveIncrementalChunkIfNeeded(force: true)
            }
        }
        
        self.isCancelled = true
    }
    
    // MARK: - Incremental Caching (Async)
    
    private func saveIncrementalChunkIfNeeded(force: Bool = false) async {
        guard let requestStartOffset = self.requestRange?.start else { return }
        
        let unsavedBytes = self.downloadedData.count - self.lastSavedOffset
        let shouldSave = force ? (unsavedBytes > 0) : (unsavedBytes >= cachingConfig.incrementalSaveThreshold)
        
        guard shouldSave else { return }
        
        let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
        guard unsavedData.count > 0 else { return }
        
        let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
        
        print("💾 [Async] Incremental save: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset)))")
        
        await assetDataManager.saveDownloadedData(Data(unsavedData), offset: actualOffset)
        self.lastSavedOffset = self.downloadedData.count
        
        print("✅ [Async] Incremental save completed")
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.type == .dataRequest else { return }
        
        self.loaderQueue.async {
            if self.isCancelled {
                print("⚠️ [Async] Received chunk AFTER cancel, ignoring")
                return
            }
            
            // Forward to AVPlayer immediately
            self.delegate?.dataRequestDidReceive(self, data)
            
            // Accumulate for caching
            self.downloadedData.append(data)
            
            print("📥 [Async] Received chunk: \(formatBytes(data.count)), accumulated: \(formatBytes(self.downloadedData.count))")
            
            // Check threshold and save asynchronously
            if self.cachingConfig.isIncrementalCachingEnabled {
                Task {
                    await self.saveIncrementalChunkIfNeeded(force: false)
                }
            }
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        print("⏹️ [Async] didCompleteWithError: \(error?.localizedDescription ?? "success")")
        
        self.isFinished = true
        
        self.loaderQueue.async {
            Task {
                if self.type == .contentInformation {
                    await self.handleContentInformationComplete(error: error)
                } else {
                    await self.handleDataRequestComplete(error: error)
                }
            }
        }
    }
    
    // MARK: - Completion Handlers (Async)
    
    private func handleContentInformationComplete(error: Error?) async {
        guard error == nil, let response = self.response as? HTTPURLResponse else {
            let responseError = error ?? ResponseUnExpectedError()
            self.delegate?.contentInformationDidComplete(self, .failure(responseError))
            return
        }
        
        let contentInformation = AssetDataContentInformation()
        
        // Parse Content-Range header
        if let rangeString = response.allHeaderFields["Content-Range"] as? String,
           let bytesString = rangeString.split(separator: "/").map({String($0)}).last,
           let bytes = Int64(bytesString) {
            contentInformation.contentLength = bytes
        }
        
        // Parse Content-Type
        if let mimeType = response.mimeType,
           let contentType = UTTypeCreatePreferredIdentifierForTag(
               kUTTagClassMIMEType, mimeType as CFString, nil)?.takeRetainedValue() {
            contentInformation.contentType = contentType as String
        }
        
        // Parse Accept-Ranges
        if let value = response.allHeaderFields["Accept-Ranges"] as? String, value == "bytes" {
            contentInformation.isByteRangeAccessSupported = true
        } else {
            contentInformation.isByteRangeAccessSupported = false
        }
        
        // Save content information asynchronously
        await assetDataManager.saveContentInformation(contentInformation)
        
        print("✅ [Async] Content info parsed: \(formatBytes(contentInformation.contentLength))")
        
        self.delegate?.contentInformationDidComplete(self, .success(contentInformation))
    }
    
    private func handleDataRequestComplete(error: Error?) async {
        // Save any remaining unsaved data
        if cachingConfig.isIncrementalCachingEnabled {
            let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
            if unsavedData.count > 0 {
                guard let requestStartOffset = self.requestRange?.start else { return }
                let actualOffset = Int(requestStartOffset) + self.lastSavedOffset
                
                print("💾 [Async] Final save: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset)))")
                
                await assetDataManager.saveDownloadedData(Data(unsavedData), offset: actualOffset)
            } else {
                print("✅ [Async] All data already saved incrementally")
            }
        } else {
            // Save entire downloaded data at once
            if self.downloadedData.count > 0, let offset = self.requestRange?.start {
                await assetDataManager.saveDownloadedData(self.downloadedData, offset: Int(offset))
            }
        }
        
        self.delegate?.dataRequestDidComplete(self, error, self.downloadedData)
    }
}

// MARK: - Delegate Protocol

@available(iOS 13.0, *)
protocol ResourceLoaderRequestAsyncDelegate: AnyObject {
    func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ data: Data)
    func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ error: Error?, _ downloadedData: Data)
    func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ result: Result<AssetDataContentInformation, Error>)
}

// MARK: - Helper Functions

private func formatBytes(_ bytes: Int) -> String {
    return formatBytes(Int64(bytes))
}

private func formatBytes(_ bytes: Int64) -> String {
    let kb = Double(bytes) / 1024.0
    let mb = kb / 1024.0
    
    if mb >= 1.0 {
        return String(format: "%.2f MB", mb)
    } else if kb >= 1.0 {
        return String(format: "%.2f KB", kb)
    } else {
        return "\(bytes) bytes"
    }
}
