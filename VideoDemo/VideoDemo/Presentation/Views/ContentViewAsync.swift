//
//  ContentViewAsync.swift
//  VideoDemo
//
//  Production async implementation using FileHandle + Actor
//  iOS 17+ minimum deployment target
//

import SwiftUI

struct ContentViewAsync: View {
    // Injected dependencies (Clean Architecture - Async mode only)
    let cacheQuery: VideoCacheQueryingAsync
    let playerManager: VideoPlayerServiceAsync
    
    @State private var selectedVideoURL: URL?
    @State private var showingClearAlert = false
    @State private var cachePercentages: [URL: Double] = [:]
    @State private var totalCacheSize: Int64 = 0
    
    init(cacheQuery: VideoCacheQueryingAsync, playerManager: VideoPlayerServiceAsync) {
        self.cacheQuery = cacheQuery
        self.playerManager = playerManager
    }
    
    // Sample video URLs
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
                    CachedVideoPlayerAsync(url: url, playerManager: playerManager, cacheQuery: cacheQuery)
                        .frame(height: 300)
                        .background(Color.black)
                        .id(url)
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
                            Text(formatBytes(totalCacheSize))
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
            .navigationTitle("Video Cache Demo (Production)")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Clear Cache", isPresented: $showingClearAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    Task {
                        await cacheQuery.clearCache()
                        selectedVideoURL = nil
                        cachePercentages.removeAll()
                        totalCacheSize = 0
                    }
                }
            } message: {
                Text("Are you sure you want to clear all cached videos?")
            }
            .onAppear {
                // Start periodic refresh for cache statuses
                Task {
                    while true {
                        try? await Task.sleep(for: .seconds(2.5))
                        await refreshAllCacheStatuses()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func cacheStatusView(for url: URL, percentage: Double) -> some View {
        if percentage >= 100.0 {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("100%")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        } else if percentage > 0 {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.orange)
                Text(String(format: "%.0f%%", percentage))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } else {
            Image(systemName: "icloud.and.arrow.down")
                .foregroundColor(.secondary)
        }
    }
    
    /// Async cache status update
    private func updateCacheStatus(for url: URL) async {
        let percentage = await cacheQuery.getCachePercentage(for: url)
        await MainActor.run {
            cachePercentages[url] = percentage
        }
    }
    
    /// Refresh all video cache statuses and total cache size
    private func refreshAllCacheStatuses() async {
        // Update individual video percentages
        for video in videoURLs {
            await updateCacheStatus(for: video.url)
        }
        
        // Update total cache size
        let size = await cacheQuery.getCacheSize()
        await MainActor.run {
            totalCacheSize = size
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
