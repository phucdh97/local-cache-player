# Race Condition Bug - ResourceLoaderRequestAsync

**Date:** January 31, 2026  
**Severity:** 🔴 CRITICAL - Causes crash  
**Error:** `Fatal error: Range requires lowerBound <= upperBound`

---

## 🐛 The Bug

```
Thread 2: Fatal error: Range requires lowerBound <= upperBound
Location: ResourceLoaderRequestAsync.swift:150
Line: let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
```

**Crash occurs when:**
- Playing a video
- User switches to another video (triggering cancel)
- Multiple network chunks arriving rapidly

---

## 🔍 Root Cause Analysis

### The Race Condition

The bug is caused by **multiple concurrent async Tasks** racing on shared mutable state without proper synchronization.

### Code Flow Leading to Crash

**File:** `ResourceLoaderRequestAsync.swift`

#### Step 1: First Chunk Arrives (Thread 1 - URLSession delegate queue)
```swift
// Line 165-189
func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.loaderQueue.async {  // ← Serial queue
        self.downloadedData.append(data)  // downloadedData = 100 bytes
        
        if self.cachingConfig.isIncrementalCachingEnabled {
            Task {  // ← Async Task 1 spawned
                await self.saveIncrementalChunkIfNeeded(force: false)
            }
        }
    }
}
```

**State:**
- `downloadedData.count` = 100
- `lastSavedOffset` = 0
- Task 1 spawned but hasn't started yet

#### Step 2: Second Chunk Arrives (Before Task 1 completes)
```swift
self.loaderQueue.async {  // ← Serial queue (different execution)
    self.downloadedData.append(data)  // downloadedData = 200 bytes
    
    Task {  // ← Async Task 2 spawned
        await self.saveIncrementalChunkIfNeeded(force: false)
    }
}
```

**State:**
- `downloadedData.count` = 200
- `lastSavedOffset` = 0
- Task 1 still pending
- Task 2 spawned

#### Step 3: Task 1 Finally Runs
```swift
// Line 142-161
private func saveIncrementalChunkIfNeeded(force: Bool = false) async {
    // ...
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)  // suffix(from: 0)
    // ... saves 100 bytes
    self.lastSavedOffset = self.downloadedData.count  // lastSavedOffset = 100
}
```

**State:**
- `downloadedData.count` = 200 (more chunks may have arrived)
- `lastSavedOffset` = 100
- Task 2 still pending

#### Step 4: User Switches Video - Cancel Called
```swift
// Line 127-138
func cancel() {
    if cachingConfig.isIncrementalCachingEnabled && self.type == .dataRequest {
        Task {  // ← Async Task 3 spawned
            await saveIncrementalChunkIfNeeded(force: true)
        }
    }
    self.isCancelled = true
}
```

**State:**
- `downloadedData.count` = 200
- `lastSavedOffset` = 100
- Task 2 still pending
- Task 3 spawned (force save)

#### Step 5: More Chunks Arrive (Before Cancel Takes Effect)
```swift
self.loaderQueue.async {
    self.downloadedData.append(data)  // downloadedData = 300 bytes
    // No new task spawned (isCancelled might be true now)
}
```

**State:**
- `downloadedData.count` = 300
- `lastSavedOffset` = 100
- Task 2 still pending
- Task 3 about to run

#### Step 6: Task 3 Runs (Force Save from Cancel)
```swift
private func saveIncrementalChunkIfNeeded(force: Bool = true) async {
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)  // suffix(from: 100)
    // ... saves 200 bytes (from offset 100 to 300)
    self.lastSavedOffset = self.downloadedData.count  // lastSavedOffset = 300 ⚠️
}
```

**State:**
- `downloadedData.count` = 300
- `lastSavedOffset` = **300** ← Updated!
- Task 2 STILL pending from Step 2

#### Step 7: Task 2 Finally Runs (The Crash!)
```swift
private func saveIncrementalChunkIfNeeded(force: Bool = false) async {
    // Task 2 was spawned when downloadedData.count was 200
    // But lastSavedOffset is now 300!
    
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
    // ☠️ CRASH: suffix(from: 300) on Data with count = 200
    // Fatal error: Range requires lowerBound (300) <= upperBound (200)
}
```

---

## 📊 Visual Timeline

```
Time →   Thread 1 (URLSession)         Async Tasks              Shared State
         (Serial Queue)                (Concurrent!)            
───────────────────────────────────────────────────────────────────────────
t0       append(100)                   -                        data=100, saved=0
         spawn Task1
         
t1       append(100)                   -                        data=200, saved=0
         spawn Task2
         
t2       append(100)                   Task1: save(0→100)       data=300, saved=0
                                       saved=100 ✓              data=300, saved=100
         
t3       cancel() called               -                        data=300, saved=100
         spawn Task3
         
t4       -                             Task3: save(100→300)     data=300, saved=300
                                       saved=300 ✓              
         
t5       -                             Task2: save(???→???)    data=300, saved=300
                                       ☠️ CRASH!                
                                       suffix(from: 300)
                                       but data.count = 200
```

---

## 🎯 Why This Happens

### The Problem: Two Different Synchronization Mechanisms

1. **GCD Serial Queue** (`loaderQueue`):
   - Serializes `downloadedData` modifications ✅
   - Ensures `downloadedData.append()` is thread-safe
   
2. **Swift Async Tasks** (`Task { ... }`):
   - Execute **concurrently** by default ❌
   - No synchronization between tasks
   - Multiple tasks can read/write `lastSavedOffset` simultaneously

### The Critical Mistake

```swift
self.loaderQueue.async {  // ← Serialized
    self.downloadedData.append(data)
    
    Task {  // ← NOT serialized! Multiple tasks run concurrently
        await self.saveIncrementalChunkIfNeeded(force: false)
    }
}
```

When you spawn a `Task`, it doesn't inherit the serial queue's synchronization. Each task runs independently and concurrently with other tasks.

---

## ✅ Solutions

### Option 1: Make ResourceLoaderRequestAsync an Actor (Recommended)

**Pros:**
- Compiler-enforced thread safety
- Natural fit for async/await
- Prevents all race conditions

**Cons:**
- Requires refactoring URLSession delegate methods
- Slightly more complex

**Implementation:**
```swift
actor ResourceLoaderRequestAsync {
    // All mutable state protected by actor isolation
    private var downloadedData: Data = Data()
    private var lastSavedOffset: Int = 0
    
    // URLSession delegate methods must be nonisolated
    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task {
            await self.handleDataReceived(data)
        }
    }
    
    // Actor-isolated method (only one executes at a time)
    private func handleDataReceived(_ data: Data) async {
        downloadedData.append(data)  // Thread-safe!
        
        if cachingConfig.isIncrementalCachingEnabled {
            await saveIncrementalChunkIfNeeded(force: false)
        }
    }
    
    // Actor-isolated (synchronized automatically)
    private func saveIncrementalChunkIfNeeded(force: Bool) async {
        // Now safe - actor ensures only one call at a time
        guard lastSavedOffset <= downloadedData.count else { return }
        
        let unsavedData = downloadedData.suffix(from: lastSavedOffset)
        // ... rest of save logic
    }
}
```

### Option 2: Serialize Save Operations (Quick Fix)

**Pros:**
- Minimal code changes
- Easy to understand

**Cons:**
- Still using GCD + async mix (not idiomatic)

**Implementation:**
```swift
class ResourceLoaderRequestAsync: NSObject, URLSessionDataDelegate {
    private let saveQueue = DispatchQueue(label: "com.videodemo.save", qos: .userInitiated)
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.loaderQueue.async {
            self.downloadedData.append(data)
            
            if self.cachingConfig.isIncrementalCachingEnabled {
                // Use serial saveQueue instead of concurrent Task
                self.saveQueue.async {
                    Task {
                        await self.saveIncrementalChunkIfNeeded(force: false)
                    }
                }
            }
        }
    }
}
```

### Option 3: Guard Against Invalid State (Defensive)

**Pros:**
- Prevents crash immediately
- Can be combined with other solutions

**Cons:**
- Doesn't fix root cause
- May lose data if state is corrupted

**Implementation:**
```swift
private func saveIncrementalChunkIfNeeded(force: Bool = false) async {
    guard let requestStartOffset = self.requestRange?.start else { return }
    
    // DEFENSIVE: Check for race condition
    guard self.lastSavedOffset <= self.downloadedData.count else {
        print("⚠️ [Async] Race condition detected!")
        print("   lastSavedOffset=\(lastSavedOffset) > downloadedData.count=\(downloadedData.count)")
        self.lastSavedOffset = self.downloadedData.count  // Reset to safe state
        return
    }
    
    let unsavedBytes = self.downloadedData.count - self.lastSavedOffset
    let shouldSave = force ? (unsavedBytes > 0) : (unsavedBytes >= cachingConfig.incrementalSaveThreshold)
    
    guard shouldSave else { return }
    
    let unsavedData = self.downloadedData.suffix(from: self.lastSavedOffset)
    // ... rest of save logic
}
```

---

## 🎓 Key Lessons

### 1. Tasks Are Concurrent by Default

```swift
Task { await doSomething() }  // Runs concurrently
Task { await doSomething() }  // Also runs concurrently
Task { await doSomething() }  // All three can run simultaneously!
```

### 2. Serial Queues Don't Serialize Tasks

```swift
queue.async {
    Task { work1() }  // ← Spawns and returns immediately
}
queue.async {
    Task { work2() }  // ← Both tasks can run concurrently!
}
```

### 3. Actors Provide Synchronization

```swift
actor MyActor {
    func doSomething() async { }  // Only one call at a time
}

let actor = MyActor()
Task { await actor.doSomething() }  // Waits if another call is running
Task { await actor.doSomething() }  // Serialized by actor
```

### 4. When Migrating GCD → Async/Await

- **GCD serial queues** = synchronization
- **Async Tasks** = concurrency (NOT synchronization!)
- Use **Actors** for synchronization in async world

---

## 🔧 Recommended Fix

**Use Option 1 (Actor)** + **Option 3 (Guard)** for defense-in-depth:

1. Make `ResourceLoaderRequestAsync` an actor for proper synchronization
2. Add defensive guards to prevent crash even if race occurs
3. Add logging to detect any remaining synchronization issues

---

## 📝 Related Files

- `ResourceLoaderRequestAsync.swift:150` - Crash location
- `ResourceLoaderRequestAsync.swift:165-189` - Where Tasks are spawned
- `ResourceLoaderRequestAsync.swift:127-138` - Cancel method that triggers race
- `FileHandleAssetRepository.swift` - The actor-based repository (good example)

---

## 🚨 Impact

**Severity:** Critical
- **When:** During video playback with rapid chunk arrival + user interaction
- **Result:** App crash (fatal error)
- **Frequency:** Intermittent (race condition - timing dependent)
- **User Impact:** Lost work, poor experience

**Must fix before production release!**

---

**Status:** Documented - awaiting fix implementation
