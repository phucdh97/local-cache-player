//
//  VideoDemoAppLegacy.swift
//  VideoDemo
//
//  Legacy app entry point using sync PINCache storage
//  For testing and comparison purposes
//
//  To activate: Comment out @main in VideoDemoApp.swift and add @main here
//

import SwiftUI

// @main  // Uncomment to activate legacy mode
struct VideoDemoAppLegacy: App {
    // Legacy dependencies with sync PINCache storage
    private let dependencies = AppDependenciesLegacy.forDemo()
    
    var body: some Scene {
        WindowGroup {
            ContentViewLegacy(
                cacheQuery: dependencies.cacheQuery,
                playerManager: dependencies.playerManager
            )
        }
    }
}
