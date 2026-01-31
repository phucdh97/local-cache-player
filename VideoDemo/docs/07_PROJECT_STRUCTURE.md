# Project Structure - Clean Architecture Organization

**Project:** VideoDemo  
**Date:** January 2026  
**Architecture:** Clean Architecture + MVVM + Dependency Injection

---

## Overview

The project is organized into distinct layers following Clean Architecture principles, ensuring:
- **Separation of Concerns** - Each layer has a single responsibility
- **Dependency Rule** - Dependencies point inward (outer layers depend on inner layers)
- **Testability** - Each layer can be tested independently
- **Maintainability** - Clear organization makes code easy to find and modify

---

## Project Structure

```
VideoDemo/VideoDemo/
├── App/                          # Application Entry & Composition Root
├── Presentation/                 # UI Layer (SwiftUI Views & ViewModels)
│   ├── Views/
│   └── ViewModels/              # (Future: Extract ViewModels here)
├── Domain/                       # Business Logic Layer
│   ├── Models/
│   ├── Services/
│   └── Protocols/
├── Data/                         # Data Layer (Repositories & Data Sources)
│   ├── Cache/
│   └── Repositories/
├── Infrastructure/               # External Dependencies & Adapters
│   └── Adapters/
└── Core/                         # Shared Resources
    ├── Configuration/
    └── Utilities/
```

---

## Layer Details

### 1. App Layer 📱
**Purpose:** Application entry point and dependency injection setup

**Files:**
```
App/
├── VideoDemoApp.swift           # SwiftUI App entry point
└── AppDependencies.swift        # Composition Root (DI Container)
```

**Responsibilities:**
- App lifecycle management
- Create and wire all dependencies once at startup
- Pass dependencies to presentation layer

**Key Point:** This is the **Composition Root** - the only place that knows about all concrete types.

---

### 2. Presentation Layer 🎨
**Purpose:** UI components and presentation logic (MVVM pattern)

**Files:**
```
Presentation/
├── Views/
│   ├── ContentView.swift         # Main list view
│   └── CachedVideoPlayer.swift  # Video player view + ViewModel
└── ViewModels/                   # (Future: Extract ViewModels here)
    └── VideoPlayerViewModel      # Currently inside CachedVideoPlayer.swift
```

**Responsibilities:**
- Display UI (SwiftUI Views)
- Handle user interactions
- Delegate business logic to Domain layer
- Observe state changes via ViewModels

**Dependencies:**
- **Inward:** Domain protocols (`VideoCacheQuerying`, services)
- **Outward:** None (depends only on abstractions)

**MVVM Pattern:**
- **View:** SwiftUI views (`ContentView`, `CachedVideoPlayer`)
- **ViewModel:** `VideoPlayerViewModel` (manages view state)
- **Model:** Domain models (`AssetData`)

**Future Improvement:** Extract `VideoPlayerViewModel` to `Presentation/ViewModels/VideoPlayerViewModel.swift`

---

### 3. Domain Layer 🎯
**Purpose:** Business logic and rules (framework-independent)

#### 3.1 Domain/Models
**Purpose:** Business entities and data structures

**Files:**
```
Domain/Models/
└── AssetData.swift              # Video asset data model
```

**Characteristics:**
- Plain Swift objects (no framework dependencies)
- Represent core business concepts
- May contain business logic relevant to the model

#### 3.2 Domain/Services
**Purpose:** Business logic and use case orchestration

**Files:**
```
Domain/Services/
├── VideoCacheManager.swift       # Cache query operations
└── CachedVideoPlayerManager.swift # Player creation & management
```

**Responsibilities:**
- Implement use cases (business operations)
- Orchestrate domain logic
- Use protocols to interact with data layer

**Pattern:** Service Layer pattern - encapsulates business operations

#### 3.3 Domain/Protocols
**Purpose:** Abstractions that define contracts (Dependency Inversion)

**Files:**
```
Domain/Protocols/
├── VideoCacheQuerying.swift     # UI-facing cache queries
├── CacheStorage.swift           # Storage operations abstraction
└── AssetDataManager.swift       # Asset data management contract
```

**Responsibilities:**
- Define interfaces for dependencies
- Enable Dependency Inversion Principle
- Make domain independent of infrastructure

**Key Point:** High-level code depends on these abstractions, not concrete implementations.

---

### 4. Data Layer 💾
**Purpose:** Data access and persistence (Repository pattern)

#### 4.1 Data/Cache
**Purpose:** Video caching implementation

**Files:**
```
Data/Cache/
├── ResourceLoader.swift          # AVAssetResourceLoader delegate
├── ResourceLoaderRequest.swift   # Network request handling
└── CachingAVURLAsset.swift      # Custom AVURLAsset with caching
```

**Responsibilities:**
- Handle AVFoundation resource loading
- Manage network requests for video data
- Integrate with cache storage

**Pattern:** Data Source pattern - manages specific data operations

#### 4.2 Data/Repositories
**Purpose:** Data access implementations (Repository pattern)

**Files:**
```
Data/Repositories/
└── PINCacheAssetDataManager.swift # Cache repository implementation
```

**Responsibilities:**
- Implement `AssetDataManager` protocol
- Manage asset data persistence
- Handle range-based chunk storage

**Pattern:** Repository pattern - abstracts data storage details from domain

---

### 5. Infrastructure Layer 🔌
**Purpose:** External dependencies and framework adapters

**Files:**
```
Infrastructure/Adapters/
└── PINCacheAdapter.swift        # PINCache wrapper
```

**Responsibilities:**
- Wrap external libraries (PINCache)
- Implement domain protocols with external dependencies
- Isolate third-party dependencies

**Key Point:** Only place that knows about PINCache. Easy to swap implementations.

**Pattern:** Adapter pattern - adapts external library to domain interface

---

### 6. Core Layer ⚙️
**Purpose:** Shared utilities and configurations

#### 6.1 Core/Configuration
**Purpose:** App-wide configuration objects

**Files:**
```
Core/Configuration/
├── CacheStorageConfiguration.swift # Infrastructure config
└── CachingConfiguration.swift      # Behavior config
```

**Responsibilities:**
- Define configuration structures
- Provide preset configurations
- Keep configuration separate from implementation

#### 6.2 Core/Utilities
**Purpose:** Helper functions and utilities

**Files:**
```
Core/Utilities/
└── ByteFormatter.swift           # Byte formatting helper
```

**Responsibilities:**
- Provide reusable helper functions
- Format data for display
- No business logic

---

## Dependency Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    App Layer                                 │
│              (VideoDemoApp, AppDependencies)                │
│                   Creates & Wires All                        │
└────────────────────┬────────────────────────────────────────┘
                     │ injects
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                 Presentation Layer                           │
│              (Views, ViewModels - MVVM)                     │
│          ContentView, CachedVideoPlayer                     │
└────────────────────┬────────────────────────────────────────┘
                     │ depends on
                     ↓
┌─────────────────────────────────────────────────────────────┐
│                  Domain Layer                                │
│     ┌──────────────┬────────────────┬─────────────────┐    │
│     │ Protocols    │   Services     │    Models       │    │
│     │ (Interfaces) │  (Use Cases)   │  (Entities)     │    │
│     └──────────────┴────────────────┴─────────────────┘    │
└────────────────────┬─────────────────────┬──────────────────┘
                     │ implemented by      │ implemented by
                     ↓                     ↓
┌─────────────────────────────────┐  ┌─────────────────────────┐
│         Data Layer               │  │  Infrastructure Layer   │
│  ┌────────────┬──────────────┐  │  │      ┌──────────┐       │
│  │   Cache    │ Repositories │  │  │      │ Adapters │       │
│  │ (Sources)  │  (Storage)   │  │  │      │(External)│       │
│  └────────────┴──────────────┘  │  │      └──────────┘       │
└─────────────────────────────────┘  └─────────────────────────┘
```

**Dependency Rule:** Dependencies point INWARD
- Outer layers depend on inner layers
- Inner layers know nothing about outer layers
- Domain is independent of UI and infrastructure

---

## Layer Characteristics

| Layer | Dependencies | Testability | Framework | Changes When |
|-------|-------------|-------------|-----------|--------------|
| **Presentation** | → Domain Protocols | High (mock protocols) | SwiftUI | UI requirements change |
| **Domain** | None (protocols only) | Very High (pure logic) | None | Business rules change |
| **Data** | → Domain Protocols | High (mock storage) | Foundation | Data source changes |
| **Infrastructure** | → Domain Protocols | High (interface tests) | PINCache | External library changes |
| **Core** | None | Very High | Foundation | Config/util needs change |

---

## Benefits of This Structure

### 1. Clear Separation of Concerns ✅
- Each folder has a single, well-defined purpose
- Easy to find where code belongs
- Prevents mixing of concerns

### 2. Dependency Inversion ✅
- Domain defines what it needs (protocols)
- Infrastructure provides implementations
- Easy to swap implementations

### 3. Testability ✅
```swift
// Test Domain layer with mocks
let mockCache = MockCacheStorage()
let cacheManager = VideoCacheManager(cache: mockCache)
```

### 4. Maintainability ✅
- Changes in UI don't affect domain logic
- Changes in data storage don't affect business rules
- Each layer can evolve independently

### 5. Team Collaboration ✅
- UI team works in `Presentation/`
- Business logic team works in `Domain/`
- Data team works in `Data/` and `Infrastructure/`
- Clear boundaries reduce conflicts

---

## MVVM in Presentation Layer

### Current Structure:
```swift
// CachedVideoPlayer.swift contains both:
struct CachedVideoPlayer: View { }      // View
class VideoPlayerViewModel: ObservableObject { }  // ViewModel
```

### Recommended Improvement:
```
Presentation/
├── Views/
│   ├── ContentView.swift
│   └── CachedVideoPlayer.swift          # View only
└── ViewModels/
    └── VideoPlayerViewModel.swift       # ViewModel extracted
```

**Benefits of extraction:**
- Clearer separation of view and logic
- Easier to test ViewModel in isolation
- Easier to reuse ViewModel with different views

---

## Common Patterns Used

### 1. Repository Pattern (Data Layer)
```swift
// Protocol in Domain
protocol AssetDataManager { }

// Implementation in Data
class PINCacheAssetDataManager: AssetDataManager { }
```

### 2. Service Layer Pattern (Domain Layer)
```swift
// VideoCacheManager encapsulates cache operations
class VideoCacheManager: VideoCacheQuerying {
    func getCachePercentage(for url: URL) -> Double { }
    func isCached(url: URL) -> Bool { }
}
```

### 3. Adapter Pattern (Infrastructure Layer)
```swift
// Adapts PINCache to CacheStorage protocol
class PINCacheAdapter: CacheStorage {
    private let cache: PINCache
}
```

### 4. Dependency Injection (App Layer)
```swift
// AppDependencies wires everything together
class AppDependencies {
    let cacheStorage: CacheStorage
    let cacheQuery: VideoCacheQuerying
    let playerManager: CachedVideoPlayerManager
}
```

---

## File Organization Rules

### When adding new code, ask:

1. **Is it UI?** → `Presentation/Views/` or `Presentation/ViewModels/`
2. **Is it business logic?** → `Domain/Services/`
3. **Is it a contract/interface?** → `Domain/Protocols/`
4. **Is it data access?** → `Data/Repositories/` or `Data/Cache/`
5. **Is it an external adapter?** → `Infrastructure/Adapters/`
6. **Is it configuration?** → `Core/Configuration/`
7. **Is it a utility?** → `Core/Utilities/`

---

## Migration Checklist

- [x] Create folder structure
- [x] Move files to appropriate folders
- [x] Verify imports and paths work
- [x] Update documentation
- [ ] Future: Extract VideoPlayerViewModel to separate file
- [ ] Future: Add unit tests for each layer
- [ ] Future: Add integration tests

---

## Next Steps

### 1. Extract ViewModels (Optional)
Move `VideoPlayerViewModel` from `CachedVideoPlayer.swift` to:
```
Presentation/ViewModels/VideoPlayerViewModel.swift
```

### 2. Add Tests
```
VideoDemoTests/
├── Presentation/
│   └── ViewModels/
├── Domain/
│   └── Services/
├── Data/
│   └── Repositories/
└── Mocks/
```

### 3. Add More Features
- New features follow the layered structure
- Start with Domain (what), then Data (how), then Presentation (show)

---

## Related Documents

- **06_CLEAN_ARCHITECTURE_REFACTORING.md** - DI refactoring details
- **01_ARCHITECTURE_OVERVIEW.md** - Overall architecture
- **REFACTORING_SUMMARY.md** - Implementation summary

---

**Status:** ✅ Clean folder structure implemented  
**Architecture:** Clean Architecture + MVVM + Repository Pattern  
**Maintainability:** High - Clear separation of concerns
