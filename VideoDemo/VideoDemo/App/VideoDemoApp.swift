//
//  VideoDemoApp.swift
//  VideoDemo
//
//  Production app entry point using async FileHandle storage
//  For legacy sync mode, change @main to VideoDemoAppLegacy
//

import SwiftUI

@main
struct VideoDemoApp: App {
    // Production dependencies with async FileHandle storage
    private let dependencies = AppDependencies.forProduction()
    
    var body: some Scene {
        WindowGroup {
            ContentViewAsync(
                cacheQuery: dependencies.cacheQuery,
                playerManager: dependencies.playerManager
            )
        }
    }
}
