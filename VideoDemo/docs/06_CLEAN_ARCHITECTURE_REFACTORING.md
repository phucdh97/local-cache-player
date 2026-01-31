# Clean Architecture Refactoring: Protocol-Based Dependency Injection

**Project:** VideoDemo  
**Date:** January 2026  
**Purpose:** Document the refactoring from singleton pattern to clean architecture with protocol-based dependency injection

---

## Overview

This document describes the comprehensive refactoring that eliminates singletons and implements clean architecture principles using:
- **Protocol-based abstractions** (Dependency Inversion Principle)
- **Dependency Injection** (explicit dependencies via constructors)
- **Composition Root** (single place for wiring dependencies)
- **Separation of Concerns** (storage config vs caching behavior)

---

## What Changed

### Before: Singleton Anti-Pattern

```swift
// Hidden global dependencies
class VideoCacheManager {
    static let shared = VideoCacheManager()
    private init() { }
}

class PINCacheAssetDataManager {
    static let Cache: PINCache = PINCache(name: "ResourceLoader")
}

// Usage - implicit coupling
let percentage = VideoCacheManager.shared.getCachePercentage(for: url)
let data = PINCacheAssetDataManager.Cache.object(forKey: key)
```

**Problems:**
- ❌ Hidden dependencies (not visible in type signatures)
- ❌ Hard to test (can't inject mocks)
- ❌ Global state (shared singletons)
- ❌ Coupled to concrete types (violates Dependency Inversion)
- ❌ Configuration mixed with implementation

### After: Clean Architecture with DI

```swift
// Protocol abstractions
protocol CacheStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func setObjectAsync(_ object: NSCoding, forKey key: String, completion: (() -> Void)?)
    var diskByteCount: UInt { get }
    func removeAllObjects()
}

protocol VideoCacheQuerying: AnyObject {
    func getCachePercentage(for url: URL) -> Double
    func isCached(url: URL) -> Bool
    // ...
}

// Dependencies created once and injected
let dependencies = AppDependencies()
ContentView(cacheQuery: dependencies.cacheQuery, playerManager: dependencies.playerManager)
```

**Benefits:**
- ✅ Explicit dependencies (visible in constructors)
- ✅ Easy to test (inject mocks)
- ✅ No global state (instance-based)
- ✅ Depends on protocols (Dependency Inversion)
- ✅ Clear separation of concerns

---

## Architecture Layers

### 1. Protocols (Domain Layer)

**Purpose:** Define abstractions that high-level code depends on

**Files:**
- `CacheStorage.swift` - Storage operations abstraction
- `VideoCacheQuerying.swift` - UI-facing cache query abstraction

**Key Point:** Domain layer defines what it needs; infrastructure layer provides it.

---

### 2. Configuration (Domain Layer)

**Purpose:** Separate infrastructure config from behavior config

**Files:**
- `CacheStorageConfiguration.swift` - Infrastructure: memory/disk limits
- `CachingConfiguration.swift` - Behavior: incremental save thresholds

**Separation Rationale:**

| Config | Concern | Changed By | Examples |
|--------|---------|------------|----------|
| `CacheStorageConfiguration` | Infrastructure limits | DevOps/Platform | Memory: 20MB, Disk: 500MB |
| `CachingConfiguration` | Caching strategy | Product/Feature | Aggressive: 256KB, Conservative: 1MB |

This separation follows Single Responsibility Principle - infrastructure concerns are independent from business logic.

---

### 3. Adapters (Infrastructure Layer)

**Purpose:** Implement protocols with concrete implementations

**Files:**
- `PINCacheAdapter.swift` - Wraps PINCache to conform to `CacheStorage`

**Key Point:** Only place that knows about PINCache. Easy to swap implementations.

```swift
final class PINCacheAdapter: CacheStorage {
    private let cache: PINCache
    
    init(configuration: CacheStorageConfiguration = .default) {
        self.cache = PINCache(name: configuration.name)
        self.cache.memoryCache.costLimit = configuration.memoryCostLimit
        self.cache.diskCache.byteLimit = configuration.diskByteLimit
    }
    
    // Implement protocol methods...
}
```

---

### 4. Core Domain (Data/Use Case Layer)

**Purpose:** Business logic that depends on abstractions, not concrete types

**Refactored Files:**

#### `PINCacheAssetDataManager.swift`
- **Before:** `static let Cache: PINCache`, creates own storage
- **After:** Takes `cache: CacheStorage` in `init`, uses injected storage
- **Benefit:** Can inject mock cache for tests

#### `VideoCacheManager.swift`
- **Before:** Singleton with `static let shared`, uses `PINCacheAssetDataManager.Cache`
- **After:** Normal class conforming to `VideoCacheQuerying`, takes `cache: CacheStorage` in `init`
- **Benefit:** Explicit dependency, testable, swappable

#### `ResourceLoader.swift`
- **Before:** Creates `PINCacheAssetDataManager(cacheKey:)` directly
- **After:** Takes `cache: CacheStorage` in `init`, passes to `PINCacheAssetDataManager(cacheKey:cache:)`
- **Benefit:** Cache dependency flows from composition root

#### `CachingAVURLAsset.swift`
- **Before:** Creates `ResourceLoader(asset:cachingConfig:)` without cache
- **After:** Takes `cache: CacheStorage` in `init`, passes to `ResourceLoader(asset:cachingConfig:cache:)`
- **Benefit:** No hidden cache creation

---

### 5. Application Layer (Use Case Orchestration)

#### `CachedVideoPlayerManager.swift`
- **Before:** Uses `VideoCacheManager.shared`, creates assets without cache dependency
- **After:** Takes `cacheQuery: VideoCacheQuerying` and `cache: CacheStorage` in `init`
- **Benefit:** All dependencies explicit, testable with mocks

---

### 6. Presentation Layer (UI)

#### `CachedVideoPlayer.swift` / `VideoPlayerViewModel`
- **Before:** Creates own `CachedVideoPlayerManager()`, uses `VideoCacheManager.shared`
- **After:** Takes `playerManager: CachedVideoPlayerManager` and `cacheQuery: VideoCacheQuerying` in `init`
- **Benefit:** UI depends on abstractions, fully testable

#### `ContentView.swift`
- **Before:** Uses `VideoCacheManager.shared` throughout
- **After:** Takes `cacheQuery: VideoCacheQuerying` and `playerManager: CachedVideoPlayerManager` in `init`
- **Benefit:** Dependencies explicit, can pass mocks for SwiftUI previews/tests

---

### 7. Composition Root (App Entry)

**Purpose:** Single place where all dependencies are created and wired together

#### `AppDependencies.swift` (NEW)

```swift
class AppDependencies {
    let cacheStorage: CacheStorage
    let cacheQuery: VideoCacheQuerying
    let playerManager: CachedVideoPlayerManager
    
    init(storageConfig: CacheStorageConfiguration = .default,
         cachingConfig: CachingConfiguration = .default) {
        
        // 1. Create infrastructure
        self.cacheStorage = PINCacheAdapter(configuration: storageConfig)
        
        // 2. Create domain services
        let cacheManager = VideoCacheManager(cache: cacheStorage)
        self.cacheQuery = cacheManager
        
        // 3. Create use cases
        self.playerManager = CachedVideoPlayerManager(
            cachingConfig: cachingConfig,
            cacheQuery: cacheManager,
            cache: cacheStorage
        )
    }
    
    static func forCurrentDevice() -> AppDependencies {
        // Device-specific configuration
    }
}
```

#### `VideoDemoApp.swift`

```swift
@main
struct VideoDemoApp: App {
    private let dependencies = AppDependencies.forCurrentDevice()
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                cacheQuery: dependencies.cacheQuery,
                playerManager: dependencies.playerManager
            )
        }
    }
}
```

**Key Points:**
- Dependencies created **once** at app startup
- **Explicit wiring** - clear dependency graph
- **Single place** to change implementations (e.g., swap cache, add logging)
- **Device-specific** configuration possible

---

## Dependency Flow

```
App Entry (VideoDemoApp)
    ↓
Composition Root (AppDependencies)
    ↓ creates
├── CacheStorage (PINCacheAdapter)
├── VideoCacheQuerying (VideoCacheManager)
└── CachedVideoPlayerManager
    ↓ inject into
UI Layer (ContentView, CachedVideoPlayer)
    ↓ use
Domain/Use Cases (ResourceLoader, PINCacheAssetDataManager)
    ↓ depend on
Protocols (CacheStorage, VideoCacheQuerying)
```

**Direction of Dependencies:**
- High-level (UI, Use Cases) → Abstractions (Protocols)
- Low-level (Infrastructure) → Implements Abstractions
- **Never:** High-level → Low-level concrete types

This follows the **Dependency Inversion Principle**.

---

## Testing Benefits

### Before (Singleton)

```swift
// ❌ Hard to test - uses global singleton
func testCachePercentage() {
    // Can't inject mock, hits real PINCache
    let percentage = VideoCacheManager.shared.getCachePercentage(for: testURL)
    // Flaky, depends on disk state
}
```

### After (DI with Protocols)

```swift
// ✅ Easy to test - inject mock
class MockCacheStorage: CacheStorage {
    var mockData: [String: Any] = [:]
    func object(forKey key: String) -> Any? { mockData[key] }
    // ... implement other methods
}

func testCachePercentage() {
    let mockCache = MockCacheStorage()
    let cacheManager = VideoCacheManager(cache: mockCache)
    
    // Set up mock data
    mockCache.mockData["test.mp4"] = mockAssetData
    
    // Test with controlled state
    let percentage = cacheManager.getCachePercentage(for: testURL)
    XCTAssertEqual(percentage, 50.0)
}
```

**Benefits:**
- Fast (no disk I/O)
- Deterministic (controlled state)
- Isolated (no side effects)

---

## Migration Summary

| Component | Before | After |
|-----------|--------|-------|
| **PINCacheAssetDataManager** | Static `Cache: PINCache` | Injected `cache: CacheStorage` |
| **VideoCacheManager** | Singleton `shared` | Instance with injected `cache: CacheStorage`, conforms to `VideoCacheQuerying` |
| **ResourceLoader** | No cache param | Takes `cache: CacheStorage` |
| **CachingAVURLAsset** | No cache param | Takes `cache: CacheStorage` |
| **CachedVideoPlayerManager** | Uses `VideoCacheManager.shared` | Takes `cacheQuery: VideoCacheQuerying` and `cache: CacheStorage` |
| **CachedVideoPlayer** | Creates own manager | Takes `playerManager` and `cacheQuery` |
| **ContentView** | Uses `VideoCacheManager.shared` | Takes `cacheQuery` and `playerManager` |
| **VideoDemoApp** | No dependencies | Creates `AppDependencies`, injects into ContentView |

---

## Configuration Examples

### Default (Standard Device)

```swift
let dependencies = AppDependencies()
// Storage: 20MB memory, 500MB disk
// Caching: Incremental, 512KB threshold
```

### High-Performance (iPad)

```swift
let dependencies = AppDependencies(
    storageConfig: .highPerformance,  // 50MB memory, 1GB disk
    cachingConfig: .aggressive         // 256KB threshold
)
```

### Low-Memory (Constrained Device)

```swift
let dependencies = AppDependencies(
    storageConfig: .lowMemory,         // 10MB memory, 250MB disk
    cachingConfig: .conservative       // 1MB threshold
)
```

### Device-Specific (Automatic)

```swift
let dependencies = AppDependencies.forCurrentDevice()
// Detects iPad vs iPhone and chooses config
```

---

## Clean Architecture Principles Applied

### 1. Dependency Inversion Principle ✅
- High-level modules (UI, use cases) depend on abstractions (`VideoCacheQuerying`, `CacheStorage`)
- Low-level modules (infrastructure) implement abstractions (`PINCacheAdapter`)
- Direction: High-level → Abstraction ← Low-level

### 2. Single Responsibility Principle ✅
- `CacheStorageConfiguration`: Infrastructure limits
- `CachingConfiguration`: Behavior strategy
- `PINCacheAdapter`: PINCache integration
- `VideoCacheManager`: Cache queries for UI
- `AppDependencies`: Dependency wiring

### 3. Open/Closed Principle ✅
- Open for extension: Can add new `CacheStorage` implementations without changing callers
- Closed for modification: Existing code doesn't change when adding new storage

### 4. Interface Segregation Principle ✅
- `CacheStorage`: Storage operations only
- `VideoCacheQuerying`: UI query operations only
- Clients depend only on interfaces they use

### 5. Dependency Injection ✅
- Constructor injection: All dependencies passed via `init`
- No service locators or hidden globals
- Explicit, testable

---

## Related Documents

- **05_VIDEO_CACHE_MANAGER_ARCHITECTURE.md** – Original guidance on moving from singleton to DI
- **03_BUGS_AND_FIXES.md** – Bug #4: Singleton anti-pattern (CachingConfiguration refactored to DI)
- **01_ARCHITECTURE_OVERVIEW.md** – Overall architecture and component roles

---

## Status

**Completed:** Full refactoring from singleton to clean architecture with protocol-based DI  
**Testing:** Ready for unit tests with mock implementations  
**Production:** Ready for deployment with explicit dependencies
