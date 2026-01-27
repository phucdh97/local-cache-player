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
    private var assetDataManager: AssetDataManager?
    
    private(set) var requestRange: RequestRange?
    private(set) var response: URLResponse?
    private(set) var downloadedData: Data = Data()
    
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
    
    weak var delegate: ResourceLoaderRequestDelegate?
    
    // MARK: - Initialization
    
    init(originalURL: URL, type: RequestType, loaderQueue: DispatchQueue, assetDataManager: AssetDataManager?) {
        self.originalURL = originalURL
        self.type = type
        self.loaderQueue = loaderQueue
        self.assetDataManager = assetDataManager
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
            
            print("🌐 Request: \(rangeHeader) for \(self.originalURL.lastPathComponent)")
            
            // 3. Create URLSession with self as delegate
            let session = URLSession(configuration: .default,
                                    delegate: self,
                                    delegateQueue: nil)
            self.session = session
            
            // 4. Create and start data task
            let dataTask = session.dataTask(with: request)
            self.dataTask = dataTask
            dataTask.resume()
        }
    }
    
    func cancel() {
        self.isCancelled = true
    }
    
    // MARK: - URLSessionDataDelegate
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.type == .dataRequest else {
            return
        }
        
        // ALWAYS dispatch back to serial queue for thread safety
        self.loaderQueue.async {
            // 1. Immediately forward to AVPlayer (streaming)
            self.delegate?.dataRequestDidReceive(self, data)
            
            // 2. Accumulate for caching later
            self.downloadedData.append(data)
            
            print("📥 Received chunk: \(formatBytes(data.count)), accumulated: \(formatBytes(self.downloadedData.count)) for \(self.originalURL.lastPathComponent)")
        }
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
                
                // SAVE TO CACHE
                if let offset = self.requestRange?.start, self.downloadedData.count > 0 {
                    print("💾 Saving \(formatBytes(self.downloadedData.count)) at offset \(offset) for \(self.originalURL.lastPathComponent)")
                    self.assetDataManager?.saveDownloadedData(self.downloadedData, offset: Int(offset))
                } else if self.downloadedData.count == 0 {
                    print("⚠️ No data to save for \(self.originalURL.lastPathComponent)")
                }
                
                // Notify delegate
                self.delegate?.dataRequestDidComplete(self, error, self.downloadedData)
            }
        }
    }
}
