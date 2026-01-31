//
//  CachingAVURLAsset.swift
//  VideoDemo
//
//  Custom AVURLAsset wrapper with resource loader for caching
//  Based on: https://github.com/ZhgChgLi/ZPlayerCacher
//

import AVFoundation
import Foundation

class CachingAVURLAsset: AVURLAsset {
    
    static let customScheme = "cachevideo"
    let originalURL: URL
    let cachingConfig: CachingConfiguration
    private var _resourceLoader: ResourceLoader?
    private let cache: CacheStorage  // Injected dependency
    
    var cacheKey: String {
        return self.url.lastPathComponent
    }
    
    static func isSchemeSupport(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        
        return ["http", "https"].contains(components.scheme)
    }
    
    init(url URL: URL, cachingConfig: CachingConfiguration = .default, cache: CacheStorage, options: [String: Any]? = nil) {
        self.originalURL = URL
        self.cachingConfig = cachingConfig
        self.cache = cache
        
        guard var components = URLComponents(url: URL, resolvingAgainstBaseURL: false) else {
            super.init(url: URL, options: options)
            return
        }
        
        // Replace scheme with custom scheme to trigger resource loader
        components.scheme = CachingAVURLAsset.customScheme
        guard let url = components.url else {
            super.init(url: URL, options: options)
            return
        }
        
        super.init(url: url, options: options)
        
        // Create and set resource loader delegate with config
        let resourceLoader = ResourceLoader(asset: self, cachingConfig: self.cachingConfig, cache: cache)
        
        // CRITICAL: Use dedicated queue, NOT main queue
        self.resourceLoader.setDelegate(resourceLoader, queue: resourceLoader.loaderQueue)
        
        // Keep strong reference to prevent deallocation
        self._resourceLoader = resourceLoader
    }
    
    override init(url URL: URL, options: [String: Any]? = nil) {
        fatalError("Use init(url:cachingConfig:cache:options:) instead - cache dependency is required")
    }
}
