//
//  ContentView.swift
//  VideoDemo
//
//  Created by Phuc Huu Do on 29/12/25.
//

import SwiftUI

struct ContentView: View {
    // Injected dependencies (Clean Architecture)
    let cacheQuery: VideoCacheQuerying?
    let cacheQueryAsync: Any?  // VideoCacheQueryingAsync for async mode
    let playerManager: VideoPlayerService
    
    @State private var selectedVideoURL: URL?
    @State private var showingClearAlert = false
    @State private var cachePercentages: [URL: Double] = [:] // Track cache percentages
    
    // Sync mode initializer
    init(cacheQuery: VideoCacheQuerying, playerManager: VideoPlayerService) {
        self.cacheQuery = cacheQuery
        self.cacheQueryAsync = nil
        self.playerManager = playerManager
    }
    
    // Async mode initializer
    @available(iOS 13.0, *)
    init(cacheQueryAsync: VideoCacheQueryingAsync, playerManager: VideoPlayerService) {
        self.cacheQuery = nil
        self.cacheQueryAsync = cacheQueryAsync
        self.playerManager = playerManager
    }
    
    // Sample video URLs (you can replace these with your own)
    let videoURLs: [(title: String, url: URL)] = [
        ("Big Buck Bunny", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!),
        ("Elephant Dream", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!),
        ("Sintel", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")!),
        ("Tears of Steel", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4")!),
        ("For Bigger Blazes", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!)
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Video player section
                if let url = selectedVideoURL {
                    if let cacheQuery = cacheQuery {
                        // Sync mode
                        CachedVideoPlayer(url: url, playerManager: playerManager, cacheQuery: cacheQuery)
                            .frame(height: 300)
                            .background(Color.black)
                            .id(url)
                    } else if #available(iOS 13.0, *), let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
                        // Async mode
                        CachedVideoPlayer(url: url, playerManager: playerManager, cacheQueryAsync: asyncQuery)
                            .frame(height: 300)
                            .background(Color.black)
                            .id(url)
                    }
                } else {
                    ZStack {
                        Color.black.opacity(0.1)
                        VStack(spacing: 12) {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Select a video to play")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(height: 300)
                }
                
                // Video list
                List {
                    Section {
                        ForEach(videoURLs, id: \.url) { video in
                            Button {
                                selectedVideoURL = video.url
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(video.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(video.url.lastPathComponent)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    // Cache status using @State
                                    cacheStatusView(for: video.url, percentage: cachePercentages[video.url] ?? 0)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Sample Videos")
                    }
                    
                    Section {
                        HStack {
                            Text("Cache Size")
                                .foregroundColor(.primary)
                            Spacer()
                            Text(formatCacheSize())
                                .foregroundColor(.secondary)
                        }
                        
                        Button(role: .destructive) {
                            showingClearAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Clear Cache")
                            }
                        }
                    } header: {
                        Text("Cache Management")
                    }
                }
            }
            .navigationTitle("Video Cache Demo")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Clear Cache", isPresented: $showingClearAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    clearCacheAction()
                }
            } message: {
                Text("Are you sure you want to clear all cached videos?")
            }
            .onAppear {
                // Start periodic refresh every 2-3 seconds
                Task {
                    while true {
                        try? await Task.sleep(for: .seconds(2.5))
                        await refreshAllCacheStatuses()
                    }
                }
            }
        }
    }
    
    private func clearCacheAction() {
        if let cacheQuery = cacheQuery {
            // Sync mode
            cacheQuery.clearCache()
        } else if #available(iOS 13.0, *), let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
            // Async mode
            Task {
                await asyncQuery.clearCache()
            }
        }
        selectedVideoURL = nil
        cachePercentages.removeAll()
    }
    
    private func formatCacheSize() -> String {
        if let cacheQuery = cacheQuery {
            return formatBytes(cacheQuery.getCacheSize())
        } else if #available(iOS 13.0, *), let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
            // For async, show placeholder (will update via Task)
            return "Loading..."
        }
        return "N/A"
    }
    
    @ViewBuilder
    private func cacheStatusView(for url: URL, percentage: Double) -> some View {
        if percentage >= 100.0 {
            // Fully cached
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("100%")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        } else if percentage > 0 {
            // Partially cached
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.orange)
                Text(String(format: "%.0f%%", percentage))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } else {
            // Not cached
            Image(systemName: "icloud.and.arrow.down")
                .foregroundColor(.secondary)
        }
    }
    
    /// Simple synchronous cache status update via polling
    /// No complex async tracking - just query cache every 2-3s
    private func updateCacheStatus(for url: URL) async {
        if let cacheQuery = cacheQuery {
            // Sync mode - use background queue
            let percentage = await Task.detached {
                cacheQuery.getCachePercentage(for: url)
            }.value
            await MainActor.run {
                cachePercentages[url] = percentage
            }
        } else if #available(iOS 13.0, *), let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
            // Async mode
            let percentage = await asyncQuery.getCachePercentage(for: url)
            await MainActor.run {
                cachePercentages[url] = percentage
            }
        }
    }
    
    private func refreshAllCacheStatuses() async {
        // Simple loop - query all videos
        for video in videoURLs {
            await updateCacheStatus(for: video.url)
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
//
//#Preview {
//    ContentView()
//}
