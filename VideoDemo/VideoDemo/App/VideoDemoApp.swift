//
//  VideoDemoApp.swift
//  VideoDemo
//
//  Created by Phuc Huu Do on 29/12/25.
//

import SwiftUI

@main
struct VideoDemoApp: App {
    // Create dependencies once at app startup (Composition Root)
    // All dependencies are wired here and passed down to views
    // 
    // MIGRATION OPTIONS:
    // 1. .forDemo() - Uses sync PINCache (suitable for demo/small videos)
    // 2. .forProduction() - Uses async FileHandle (suitable for production/large videos)
    // 3. .forCurrentDevice() - Auto-detects device and uses async mode
    //
    // Change this line to switch modes:
    private let dependencies = AppDependencies.forProduction()  // Production async mode
    // private let dependencies = AppDependencies.forDemo()     // Demo sync mode
    
    var body: some Scene {
        WindowGroup {
            if dependencies.storageMode == .sync, let cacheQuery = dependencies.cacheQuery {
                // Sync mode (PINCache)
                ContentView(
                    cacheQuery: cacheQuery,
                    playerManager: dependencies.playerManager
                )
            } else if #available(iOS 13.0, *), let cacheQueryAsync = dependencies.cacheQueryAsync {
                // Async mode (FileHandle)
                ContentView(
                    cacheQueryAsync: cacheQueryAsync,
                    playerManager: dependencies.playerManager
                )
            } else {
                // Fallback
                Text("Unsupported configuration")
            }
        }
    }
}
