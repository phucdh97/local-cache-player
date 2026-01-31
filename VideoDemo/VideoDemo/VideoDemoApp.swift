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
