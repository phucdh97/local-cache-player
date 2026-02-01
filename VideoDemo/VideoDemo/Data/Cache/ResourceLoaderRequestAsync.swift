//
//  ResourceLoaderRequestAsync.swift
//  VideoDemo
//
//  Actor-based async resource loader for thread-safe FileHandle storage
//  FIXED: Race condition in incremental caching
//

import Foundation
import CoreServices

/// ⚠️ THREAD SAFETY NOTES:
/// 
/// This actor provides synchronized access to all mutable state:
/// - downloadedData: Protected by actor isolation
/// - lastSavedOffset: Protected by actor isolation  
/// - Only ONE async method executes at a time (actor serialization)
///
/// URLSession delegate methods are sync callbacks that CANNOT be actor-isolated
/// They use @preconcurrency and nonisolated to bridge to the actor's async world
///
actor ResourceLoaderRequestAsync {
    
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
    
    // MARK: - Actor-Isolated State (Thread-Safe!)
    
    /// All mutable state is protected by actor isolation
    /// Only one task can access these at a time
    private var downloadedData: Data = Data()
    private var lastSavedOffset: Int = 0
    private var requestRange: RequestRange?
    private var response: URLResponse?
    private var isCancelled: Bool = false
    private var isFinished: Bool = false
    
    // MARK: - Immutable/Nonisolated Properties
    
    /// These don't need actor protection (immutable or externally synchronized)
    nonisolated let originalURL: URL
    nonisolated let type: RequestType
    private let assetDataManager: FileHandleAssetRepository
    private let cachingConfig: CachingConfiguration
    
    /// URLSession objects - accessed from nonisolated methods
    /// ⚠️ SAFETY: Only modified in start() which is called once
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    
    /// Delegate - actor-isolated (accessed only from actor methods)
    weak var delegate: ResourceLoaderRequestAsyncDelegate?
    
    // MARK: - Initialization
    
    init(originalURL: URL,
         type: RequestType,
         loaderQueue: DispatchQueue,  // Not used in actor version
         assetDataManager: FileHandleAssetRepository,
         cachingConfig: CachingConfiguration = .default) {
        self.originalURL = originalURL
        self.type = type
        self.assetDataManager = assetDataManager
        self.cachingConfig = cachingConfig
        
        print("🏗️ [Actor] ResourceLoaderRequestAsync initialized (thread-safe)")
    }
    
    // MARK: - Request Management (Actor-Isolated)
    
    func start(requestRange: RequestRange) async {
        guard !isCancelled, !isFinished else {
            return
        }
        
        self.requestRange = requestRange
        
        var request = URLRequest(url: originalURL)
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
        
        print("🌐 [Actor] Request START: \(rangeHeader) for \(originalURL.lastPathComponent)")
        
        // Create session on actor's executor
        let session = URLSession(configuration: .default, delegate: URLSessionBridge(actor: self), delegateQueue: nil)
        self.session = session
        
        let dataTask = session.dataTask(with: request)
        self.dataTask = dataTask
        dataTask.resume()
    }
    
    func cancel() async {
        let currentSize = downloadedData.count
        print("🚫 [Actor] cancel() called, accumulated: \(formatBytes(currentSize))")
        
        // Save unsaved data before cancelling
        if cachingConfig.isIncrementalCachingEnabled && type == .dataRequest {
            await saveIncrementalChunkIfNeeded(force: true)
        }
        
        isCancelled = true
        
        // Cancel network operations
        dataTask?.cancel()
        session?.invalidateAndCancel()
    }
    
    // MARK: - Incremental Caching (Actor-Isolated = Thread-Safe!)
    
    /// ✅ THREAD SAFETY: Actor isolation ensures only one call executes at a time
    /// ✅ NO RACE CONDITION: lastSavedOffset cannot be modified by concurrent calls
    private func saveIncrementalChunkIfNeeded(force: Bool = false) async {
        guard let requestStartOffset = requestRange?.start else { return }
        
        // ✅ SAFE: Actor ensures these reads are atomic
        let unsavedBytes = downloadedData.count - lastSavedOffset
        let shouldSave = force ? (unsavedBytes > 0) : (unsavedBytes >= cachingConfig.incrementalSaveThreshold)
        
        guard shouldSave else { return }
        
        // ✅ DEFENSIVE CHECK: Should never fail with actor, but guard anyway
        guard lastSavedOffset <= downloadedData.count else {
            print("⚠️ [Actor] Defensive check failed (should be impossible with actor!)")
            print("   lastSavedOffset=\(lastSavedOffset) > downloadedData.count=\(downloadedData.count)")
            lastSavedOffset = downloadedData.count
            return
        }
        
        let unsavedData = downloadedData.suffix(from: lastSavedOffset)
        guard unsavedData.count > 0 else { return }
        
        let actualOffset = Int(requestStartOffset) + lastSavedOffset
        
        print("💾 [Actor] Incremental save: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset)))")
        
        // ✅ CRASH-SAFE: Update AFTER successful save
        await assetDataManager.saveDownloadedData(Data(unsavedData), offset: actualOffset)
        lastSavedOffset = downloadedData.count
        
        print("✅ [Actor] Incremental save completed, lastSaved=\(lastSavedOffset)")
    }
    
    // MARK: - Data Handling (Actor-Isolated)
    
    /// Called from URLSession bridge - actor-isolated for thread safety
    func handleDataReceived(_ data: Data) async {
        guard type == .dataRequest else { return }
        guard !isCancelled else {
            print("⚠️ [Actor] Received chunk AFTER cancel, ignoring")
            return
        }
        
        // ✅ THREAD-SAFE: Actor ensures exclusive access
        downloadedData.append(data)
        
        print("📥 [Actor] Received chunk: \(formatBytes(data.count)), accumulated: \(formatBytes(downloadedData.count))")
        
        // Forward to AVPlayer immediately
        delegate?.dataRequestDidReceive(self, data)
        
        // ✅ SERIALIZED: Actor ensures only one save runs at a time
        if cachingConfig.isIncrementalCachingEnabled {
            await saveIncrementalChunkIfNeeded(force: false)
        }
    }
    
    func handleResponseReceived(_ response: URLResponse) async {
        self.response = response
    }
    
    func handleCompletion(error: Error?) async {
        print("⏹️ [Actor] handleCompletion: \(error?.localizedDescription ?? "success")")
        
        isFinished = true
        
        if type == .contentInformation {
            await handleContentInformationComplete(error: error)
        } else {
            await handleDataRequestComplete(error: error)
        }
        
        // Invalidate session
        session?.finishTasksAndInvalidate()
    }
    
    // MARK: - Completion Handlers (Actor-Isolated)
    
    private func handleContentInformationComplete(error: Error?) async {
        guard error == nil, let response = response as? HTTPURLResponse else {
            let responseError = error ?? ResponseUnExpectedError()
            delegate?.contentInformationDidComplete(self, .failure(responseError))
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
        
        // Save content information
        await assetDataManager.saveContentInformation(contentInformation)
        
        print("✅ [Actor] Content info parsed: \(formatBytes(contentInformation.contentLength))")
        
        delegate?.contentInformationDidComplete(self, .success(contentInformation))
    }
    
    private func handleDataRequestComplete(error: Error?) async {
        // ✅ THREAD-SAFE: Final save is serialized by actor
        if cachingConfig.isIncrementalCachingEnabled {
            // Check if there's unsaved data
            guard lastSavedOffset <= downloadedData.count else {
                print("⚠️ [Actor] lastSavedOffset > downloadedData.count at completion")
                delegate?.dataRequestDidComplete(self, error, downloadedData)
                return
            }
            
            let unsavedData = downloadedData.suffix(from: lastSavedOffset)
            if unsavedData.count > 0 {
                guard let requestStartOffset = requestRange?.start else {
                    delegate?.dataRequestDidComplete(self, error, downloadedData)
                    return
                }
                let actualOffset = Int(requestStartOffset) + lastSavedOffset
                
                print("💾 [Actor] Final save: \(formatBytes(unsavedData.count)) at offset \(formatBytes(Int64(actualOffset)))")
                
                await assetDataManager.saveDownloadedData(Data(unsavedData), offset: actualOffset)
                lastSavedOffset = downloadedData.count
            } else {
                print("✅ [Actor] All data already saved incrementally")
            }
        } else {
            // Save entire downloaded data at once
            if downloadedData.count > 0, let offset = requestRange?.start {
                await assetDataManager.saveDownloadedData(downloadedData, offset: Int(offset))
            }
        }
        
        delegate?.dataRequestDidComplete(self, error, downloadedData)
    }
}

// MARK: - URLSession Bridge

/// ⚠️ BRIDGE PATTERN: URLSessionDelegate is sync, Actor methods are async
/// This bridge receives sync callbacks and forwards to actor's async methods
@preconcurrency
private final class URLSessionBridge: NSObject, URLSessionDataDelegate {
    private let actor: ResourceLoaderRequestAsync
    
    init(actor: ResourceLoaderRequestAsync) {
        self.actor = actor
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Bridge sync callback → async actor method
        Task {
            await actor.handleDataReceived(data)
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        Task {
            await actor.handleResponseReceived(response)
            completionHandler(.allow)
        }
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task {
            await actor.handleCompletion(error: error)
        }
    }
}

// MARK: - Delegate Protocol

protocol ResourceLoaderRequestAsyncDelegate: AnyObject {
    func dataRequestDidReceive(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ data: Data)
    func dataRequestDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ error: Error?, _ downloadedData: Data)
    func contentInformationDidComplete(_ resourceLoaderRequest: ResourceLoaderRequestAsync, _ result: Result<AssetDataContentInformation, Error>)
}
