//
//  CacheStorage.swift
//  VideoDemo
//
//  Protocol abstracting cache storage operations (Clean Architecture - Dependency Inversion)
//  Allows testing with mocks and swapping implementations without changing callers
//

import Foundation

/// Abstract cache storage protocol - domain layer doesn't depend on concrete PINCache
protocol CacheStorage: AnyObject {
    /// Retrieve an object from cache by key
    func object(forKey key: String) -> Any?
    
    /// Store an object in cache asynchronously (non-blocking)
    /// - Parameters:
    ///   - object: Object to store (must conform to NSCoding)
    ///   - key: Key to store under
    func setObjectAsync(_ object: NSCoding, forKey key: String)
    
    /// Get total disk cache size in bytes
    var diskByteCount: UInt { get }
    
    /// Remove all objects from cache
    func removeAllObjects()
}
