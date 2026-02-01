//
//  CachingAVURLAssetAsync.swift
//  VideoDemo
//
//  Async AVURLAsset wrapper using FileHandle-based storage
//  Production implementation for iOS 17+
//

import AVFoundation
import Foundation

/// Async caching asset using FileHandle storage
/// Uses ResourceLoaderAsync for efficient large file handling
class CachingAVURLAssetAsync: AVURLAsset {
    
    static let customScheme = "cachevideo"
    let originalURL: URL
    let cachingConfig: CachingConfiguration
    private var _resourceLoader: ResourceLoaderAsync?
    private let repository: FileHandleAssetRepository
    
    var cacheKey: String {
        // Use consistent key format: URL's last path component
        return originalURL.lastPathComponent
    }
    
    static func isSchemeSupport(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return ["http", "https"].contains(components.scheme)
    }
    
    init(url URL: URL, cachingConfig: CachingConfiguration = .default, repository: FileHandleAssetRepository, options: [String: Any]? = nil) {
        self.originalURL = URL
        self.cachingConfig = cachingConfig
        self.repository = repository
        
        guard var components = URLComponents(url: URL, resolvingAgainstBaseURL: false) else {
            super.init(url: URL, options: options)
            return
        }
        
        // Replace scheme with custom scheme to trigger resource loader
        components.scheme = CachingAVURLAssetAsync.customScheme
        guard let url = components.url else {
            super.init(url: URL, options: options)
            return
        }
        
        super.init(url: url, options: options)
        
        // Create and set async resource loader delegate
        let resourceLoader = ResourceLoaderAsync(
            asset: self,
            cachingConfig: cachingConfig,
            repository: repository
        )
        
        // Use dedicated queue, NOT main queue
        self.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.loaderQueue)
        
        // Keep strong reference
        self._resourceLoader = resourceLoader
        
        print("🎬 [Async] CachingAVURLAssetAsync created for \(URL.lastPathComponent)")
    }
    
    override init(url URL: URL, options: [String: Any]? = nil) {
        fatalError("Use init(url:cachingConfig:repository:options:) instead - repository dependency is required")
    }
}
