//
//  ContentView.swift
//  VideoDemo
//
//  Created by Phuc Huu Do on 29/12/25.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedVideoURL: URL?
    @State private var showingClearAlert = false
    @State private var cacheRefreshTrigger = false // For refreshing cache status
    
    // Sample video URLs (you can replace these with your own)
    let videoURLs: [(title: String, url: URL)] = [
        ("Big Buck Bunny", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!),
        ("Elephant Dream", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!),
        ("For Bigger Blazes", URL(string: "http://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!)
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Video player section
                if let url = selectedVideoURL {
                    CachedVideoPlayer(url: url)
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
                                    
                                    // Cache status indicator
                                    cacheStatusView(for: video.url)
                                        .id("\(video.url.absoluteString)-\(cacheRefreshTrigger)") // Refresh status
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
                            Text(formatBytes(VideoCacheManager.shared.getCacheSize()))
                                .foregroundColor(.secondary)
                                .id(cacheRefreshTrigger) // Refresh just this text
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
                    VideoCacheManager.shared.clearCache()
                    selectedVideoURL = nil
                    cacheRefreshTrigger.toggle() // Trigger refresh
                }
            } message: {
                Text("Are you sure you want to clear all cached videos?")
            }
            .onAppear {
                // Refresh cache status periodically
                Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                    cacheRefreshTrigger.toggle()
                }
            }
        }
    }
    
    @ViewBuilder
    private func cacheStatusView(for url: URL) -> some View {
        let cacheManager = VideoCacheManager.shared
        
        if cacheManager.isCached(url: url) {
            // Fully cached
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("100%")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        } else if cacheManager.isPartiallyCached(for: url) {
            // Partially cached
            let percentage = cacheManager.getCachePercentage(for: url)
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
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    ContentView()
}
