//
//  VideoCacheServiceAsync.swift
//  VideoDemo
//
//  Async cache service for UI-facing queries
//  Uses FileHandle-based repositories for production use
//

import Foundation

/// Async cache service implementation using FileHandle-based storage
/// All operations are non-blocking and safe for main thread usage
@available(iOS 13.0, *)
class VideoCacheServiceAsync: VideoCacheQueryingAsync {
    
    // MARK: - Properties
    
    private let cacheDirectory: URL
    private let repositoryCache = NSCache<NSString, AnyObject>()
    
    // MARK: - Initialization
    
    init(cacheDirectory: URL? = nil) {
        if let directory = cacheDirectory {
            self.cacheDirectory = directory
        } else {
            // Default to Caches directory
            let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheDirectory = cachesURL.appendingPathComponent("VideoCache")
        }
        
        // Create directory if needed
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }
    
    // MARK: - VideoCacheQueryingAsync Protocol
    
    func getCachePercentage(for url: URL) async -> Double {
        let repository = await getRepository(for: url)
        
        guard let assetData = await repository.retrieveAssetData(),
              assetData.contentInformation.contentLength > 0 else {
            return 0.0
        }
        
        let totalCached = assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
        let percentage = (Double(totalCached) / Double(assetData.contentInformation.contentLength)) * 100.0
        
        return min(100.0, max(0.0, percentage))
    }
    
    func isCached(url: URL) async -> Bool {
        let percentage = await getCachePercentage(for: url)
        return percentage >= 99.0  // Consider cached if >= 99%
    }
    
    func getCachedFileSize(for url: URL) async -> Int64 {
        let repository = await getRepository(for: url)
        
        guard let assetData = await repository.retrieveAssetData() else {
            return 0
        }
        
        return assetData.cachedRanges.reduce(Int64(0)) { $0 + $1.length }
    }
    
    func getCacheSize() async -> Int64 {
        var totalSize: Int64 = 0
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: []
            )
            
            for url in contents where url.pathExtension == "video" {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = attributes[.size] as? Int64 ?? 0
                totalSize += size
            }
        } catch {
            print("❌ Failed to calculate cache size: \(error)")
        }
        
        return totalSize
    }
    
    func clearCache() async {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            
            for url in contents {
                try FileManager.default.removeItem(at: url)
            }
            
            // Clear repository cache
            repositoryCache.removeAllObjects()
            
            print("🗑️ [FileHandle] Cache cleared")
        } catch {
            print("❌ Failed to clear cache: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    /// Get or create repository for URL
    private func getRepository(for url: URL) async -> FileHandleAssetRepository {
        let cacheKey = url.absoluteString
        
        // Check cache first
        if let cached = repositoryCache.object(forKey: cacheKey as NSString) as? FileHandleAssetRepository {
            return cached
        }
        
        // Create new repository
        do {
            let repository = try FileHandleAssetRepository(
                cacheKey: cacheKey,
                cacheDirectory: cacheDirectory
            )
            
            // Cache the repository (stored as AnyObject for NSCache)
            repositoryCache.setObject(repository as AnyObject, forKey: cacheKey as NSString)
            
            return repository
        } catch {
            print("❌ Failed to create repository: \(error)")
            // Return a new instance anyway (will fail operations but won't crash)
            return try! FileHandleAssetRepository(cacheKey: cacheKey, cacheDirectory: cacheDirectory)
        }
    }
}
