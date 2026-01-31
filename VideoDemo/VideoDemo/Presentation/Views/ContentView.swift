//
//  ContentView.swift
//  VideoDemo
//
//  Created by Phuc Huu Do on 29/12/25.
//

import SwiftUI

struct ContentView: View {
    // Injected dependencies (Clean Architecture)
    let cacheQuery: VideoCacheQuerying
    let playerManager: VideoPlayerService
    
    @State private var selectedVideoURL: URL?
    @State private var showingClearAlert = false
    @State private var cachePercentages: [URL: Double] = [:] // Track cache percentages
    
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
                    CachedVideoPlayer(url: url, playerManager: playerManager, cacheQuery: cacheQuery)
                        .frame(height: 300)
                        .background(Color.black)
                        .id(url) // Force recreation when URL changes
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
                            Text(formatBytes(cacheQuery.getCacheSize()))
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
                    cacheQuery.clearCache()
                    selectedVideoURL = nil
                    // Reset all percentages
                    cachePercentages.removeAll()
                }
            } message: {
                Text("Are you sure you want to clear all cached videos?")
            }
            .onAppear {
                // Start periodic refresh every 2-3 seconds
                // UI-driven polling approach (no complex data layer logic)
                Task {
                    while true {
                        try? await Task.sleep(for: .seconds(2.5))
                        refreshAllCacheStatuses()
                    }
                }
            }
        }
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
    private func updateCacheStatus(for url: URL) {
        // Synchronous call - cache operations are thread-safe
        let percentage = cacheQuery.getCachePercentage(for: url)
        cachePercentages[url] = percentage
    }
    
    private func refreshAllCacheStatuses() {
        // Simple loop - no complex task groups needed
        for video in videoURLs {
            updateCacheStatus(for: video.url)
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
