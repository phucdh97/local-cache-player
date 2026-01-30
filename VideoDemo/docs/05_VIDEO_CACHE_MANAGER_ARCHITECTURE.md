# VideoCacheManager: Singleton vs. Instance (Clean Architecture)

**Project:** VideoDemo  
**Date:** January 2026  
**Purpose:** Document why singleton is used today and how to align with clean architecture using instance + dependency injection

---

## Current Design: VideoCacheManager as Singleton

Today `VideoCacheManager` is implemented as a **singleton**:

```swift
class VideoCacheManager {
    static let shared = VideoCacheManager()
    
    private init() {
        print("📦 VideoCacheManager initialized")
    }
    
    func getCachePercentage(for url: URL) -> Double { ... }
    func isCached(url: URL) -> Bool { ... }
    func getCachedFileSize(for url: URL) -> Int64 { ... }
    // ...
}
```

**Usage:** Any code that needs cache queries calls `VideoCacheManager.shared`.

---

## Why the Singleton Is Questionable (Clean Architecture)

### 1. Hidden Dependency

Code that uses `VideoCacheManager.shared` is implicitly coupled to that concrete type. The dependency is not visible in the type signature or initializer, so it's hard to see what a component needs.

### 2. Hard to Test

You cannot easily replace the singleton with a mock or stub. Tests either hit the real cache (slow, flaky) or must reset/replace the singleton (fragile).

### 3. Global State

A single shared instance is global state. Clean architecture favors explicit dependencies and avoids hidden globals.

### 4. Violates Dependency Inversion

High-level code (e.g. ViewModel) should depend on **abstractions** (protocols), not on a concrete `VideoCacheManager` singleton.

---

## Do We Have to Use a Singleton Here?

**No.** The singleton was chosen for convenience (easy to call from anywhere), not because the design requires a single shared instance. The same “single place for cache queries” can be achieved with **one instance created at app startup and passed in (dependency injection)**.

---

## Better Approach: Instance + Dependency Injection

Use **one instance** of the cache manager and **inject** it wherever cache queries are needed, instead of a singleton.

### 1. Make VideoCacheManager a Normal Type (No Singleton)

- Remove `static let shared` and `private init()`.
- Use a normal `init()` (optionally taking dependencies if you want to go further, e.g. something that provides cache/key logic).
- Whoever owns the “app boundary” (e.g. `ContentView`, `App`, or a composition root) creates **one** `VideoCacheManager()` and passes it down.

So “use instance” means: one instance created at the composition root and injected, not a global shared instance.

### 2. Inject It Into the Player Manager

Today `CachedVideoPlayerManager` uses `VideoCacheManager.shared` internally. Cleaner:

- `CachedVideoPlayerManager` takes both `cachingConfig` and a **cache query dependency** in `init` (e.g. `cacheManager: VideoCacheManager`, or better a protocol).
- The same instance is passed in from the composition root; no `.shared` inside the player manager.

### 3. Inject Into the UI Layer

- ViewModel or View that needs cache percentage or “is cached?” gets a **cache query** dependency in its initializer (again, protocol is best).
- The same `VideoCacheManager` instance (or a protocol implementation) is passed from the composition root (e.g. from the parent that creates the ViewModel).

So “other way” means **dependency injection** (constructor or property) instead of pulling a singleton from the type.

---

## Even Cleaner: Protocol (Dependency Inversion)

Define what the UI/player need from “the cache” and depend on that, not on `VideoCacheManager`:

### Define a Protocol

```swift
/// Abstraction for UI and player layer cache queries (Clean Architecture: Dependency Inversion)
protocol VideoCacheQuerying: AnyObject {
    func getCachePercentage(for url: URL) -> Double
    func isCached(url: URL) -> Bool
    func getCachedFileSize(for url: URL) -> Int64
    func getCacheSize() -> Int64
    func clearCache()
    // ... other UI-facing methods
}
```

### VideoCacheManager Implements the Protocol

```swift
class VideoCacheManager: VideoCacheQuerying {
    // No static let shared
    init() { ... }
    
    func getCachePercentage(for url: URL) -> Double { ... }
    func isCached(url: URL) -> Bool { ... }
    // ...
}
```

### High-Level Code Depends on the Protocol

```swift
class CachedVideoPlayerManager {
    private let cachingConfig: CachingConfiguration
    private let cacheQuery: VideoCacheQuerying  // Protocol, not concrete type
    
    init(cachingConfig: CachingConfiguration = .default,
         cacheQuery: VideoCacheQuerying) {
        self.cachingConfig = cachingConfig
        self.cacheQuery = cacheQuery
    }
    
    func createPlayerItem(with url: URL) -> AVPlayerItem {
        if cacheQuery.isCached(url: url) { ... }
        // ...
    }
}
```

### Composition Root Creates One Instance and Injects It

```swift
// App or SceneDelegate or ContentView
let cacheManager = VideoCacheManager()  // One instance
let playerManager = CachedVideoPlayerManager(
    cachingConfig: .default,
    cacheQuery: cacheManager
)
```

Benefits:

- **Testability:** Tests inject a mock that conforms to `VideoCacheQuerying`.
- **Explicit dependencies:** Dependencies appear in initializers.
- **Dependency Inversion:** High-level code depends on `VideoCacheQuerying`, not `VideoCacheManager`.
- **Flexibility:** You can swap implementations (e.g. stub, analytics wrapper) without changing callers.

---

## Summary

| Question | Answer |
|----------|--------|
| Why was singleton used? | Convenience and “single place” for cache queries. That does not require a singleton. |
| Should we use singleton for clean architecture? | No. Prefer **one instance + dependency injection**. |
| Can we use instance or another way? | Yes. **Instance:** create one `VideoCacheManager` at the composition root and inject it. **Other way:** introduce a **protocol** for cache queries and inject an implementation (e.g. `VideoCacheManager`) as that protocol. |

For clean architecture, **don’t use a singleton here**; use an instance (or protocol + instance) and inject it where needed.

---

## Migration Path (If Refactoring Later)

1. **Define protocol** `VideoCacheQuerying` with the current public API of `VideoCacheManager`.
2. **Make** `VideoCacheManager` conform to `VideoCacheQuerying` and remove `static let shared` / `private init()`.
3. **Add** `cacheQuery: VideoCacheQuerying` (or `VideoCacheManager`) to `CachedVideoPlayerManager.init`, and use it instead of `VideoCacheManager.shared`.
4. **Create** one `VideoCacheManager()` at the composition root (e.g. in `VideoDemoApp` or the view that owns the player).
5. **Pass** that instance into `CachedVideoPlayerManager` and any ViewModel/View that needs cache queries (e.g. via `@EnvironmentObject`, custom environment, or initializer).
6. **Optionally** introduce a mock type conforming to `VideoCacheQuerying` for unit tests.

---

## Related Documents

- **01_ARCHITECTURE_OVERVIEW.md** – Overall architecture and component roles  
- **03_BUGS_AND_FIXES.md** – Bug #4: Singleton anti-pattern (CachingConfiguration refactored to DI)  
- **04_COMPARISON_WITH_ORIGINAL.md** – Original vs. enhanced design

---

**Status:** Guidance for future refactor  
**Clean Architecture:** Prefer instance + DI (and protocol) over singleton for `VideoCacheManager`
