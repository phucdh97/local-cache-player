//
//  CachedVideoPlayer.swift
//  VideoDemo
//
//  SwiftUI video player with caching support
//  Refactored to use new ResourceLoader architecture
//

import SwiftUI
import AVKit
import AVFoundation
import Combine

struct CachedVideoPlayer: View {
    let url: URL
    @StateObject private var viewModel: VideoPlayerViewModel
    
    init(url: URL, playerManager: VideoPlayerService, cacheQuery: VideoCacheQuerying) {
        self.url = url
        _viewModel = StateObject(wrappedValue: VideoPlayerViewModel(url: url, playerManager: playerManager, cacheQuery: cacheQuery))
    }
    
    var body: some View {
        VStack {
            if let player = viewModel.player {
                VideoPlayer(player: player)
                    .onAppear {
                        viewModel.play()
                    }
                    .onDisappear {
                        viewModel.pause()
                        viewModel.stopDownload()
                    }
            } else {
                ProgressView("Loading video...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Controls
            VStack(spacing: 12) {
                // Progress bar
                if let currentTime = viewModel.currentTime,
                   let duration = viewModel.duration,
                   duration > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(formatTime(currentTime))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(formatTime(duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        ProgressView(value: currentTime, total: duration)
                            .progressViewStyle(.linear)
                    }
                }
                
                // Cache status
                HStack(spacing: 16) {
                    if viewModel.isCached {
                        Label("Cached", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else if viewModel.isDownloading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Downloading...")
                                .font(.caption)
                        }
                        .foregroundColor(.blue)
                    } else {
                        Label("Not cached", systemImage: "icloud.and.arrow.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Playback controls
                    HStack(spacing: 20) {
                        Button {
                            viewModel.seekBackward()
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.title2)
                        }
                        
                        Button {
                            viewModel.togglePlayPause()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.largeTitle)
                        }
                        
                        Button {
                            viewModel.seekForward()
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.title2)
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
}

class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var isCached = false
    @Published var isDownloading = false
    @Published var currentTime: Double?
    @Published var duration: Double?
    
    private let url: URL
    private let playerManager: VideoPlayerService  // Injected dependency
    private let cacheQuery: VideoCacheQuerying?          // Injected dependency (sync mode)
    private let cacheQueryAsync: Any?  // VideoCacheQueryingAsync (async mode)
    private let cacheQueryQueue = DispatchQueue(label: "com.videodemo.cacheQuery", qos: .userInitiated)
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    
    // Sync mode initializer
    init(url: URL, playerManager: VideoPlayerService, cacheQuery: VideoCacheQuerying) {
        self.url = url
        self.playerManager = playerManager
        self.cacheQuery = cacheQuery
        self.cacheQueryAsync = nil
        setupPlayer()
        checkCacheStatus()
    }
    
    // Async mode initializer
    @available(iOS 13.0, *)
    init(url: URL, playerManager: VideoPlayerService, cacheQueryAsync: VideoCacheQueryingAsync) {
        self.url = url
        self.playerManager = playerManager
        self.cacheQuery = nil
        self.cacheQueryAsync = cacheQueryAsync
        setupPlayer()
        checkCacheStatusAsync()
    }
    
    private func setupPlayer() {
        // Check cache status off the main thread (for logging)
        fetchIsCached { [weak self] cached in
            guard let self = self else { return }
            if cached {
                // Log to be easy to debug for now, remove later
                print("▶️ Playing cached video: \(self.url.lastPathComponent)")
            }
        }

        // Create player item using service
        let playerItem = playerManager.createPlayerItem(with: url)

        DispatchQueue.main.async {
            self.player = AVPlayer(playerItem: playerItem)
        }
        
        // Observe player status
        statusObserver = playerItem.observe(\.status) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self?.duration = item.duration.seconds
                    self?.isDownloading = false
                } else if item.status == .failed {
                    print("❌ Player item failed: \(item.error?.localizedDescription ?? "unknown")")
                    self?.isDownloading = false
                }
            }
        }
        
        // Add time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        DispatchQueue.main.async {
            self.timeObserver = self.player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.currentTime = time.seconds
            }
        }
        
        // Observe download status
        DispatchQueue.main.async {
            if !self.isCached {
                self.isDownloading = true
            }
        }
    }
    
    private func checkCacheStatus() {
        fetchIsCached { [weak self] cached in
            guard let self = self else { return }
            self.isCached = cached
            self.isDownloading = !cached
        }
    }
    
    @available(iOS 13.0, *)
    private func checkCacheStatusAsync() {
        Task {
            if let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
                let cached = await asyncQuery.isCached(url: url)
                await MainActor.run {
                    self.isCached = cached
                    self.isDownloading = !cached
                }
            }
        }
    }

    private func fetchIsCached(completion: @escaping (Bool) -> Void) {
        if let cacheQuery = cacheQuery {
            // Sync mode: use background queue
            cacheQueryQueue.async { [weak self] in
                guard let self = self else { return }
                let cached = cacheQuery.isCached(url: self.url)
                DispatchQueue.main.async {
                    completion(cached)
                }
            }
        } else if #available(iOS 13.0, *), let asyncQuery = cacheQueryAsync as? VideoCacheQueryingAsync {
            // Async mode: use Task
            Task {
                let cached = await asyncQuery.isCached(url: url)
                await MainActor.run {
                    completion(cached)
                }
            }
        } else {
            completion(false)
        }
    }
    
    func play() {
        player?.play()
        isPlaying = true
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seekForward() {
        guard let currentTime = player?.currentTime() else { return }
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: 10, preferredTimescale: 1))
        player?.seek(to: newTime)
    }
    
    func seekBackward() {
        guard let currentTime = player?.currentTime() else { return }
        let newTime = CMTimeSubtract(currentTime, CMTime(seconds: 10, preferredTimescale: 1))
        player?.seek(to: newTime)
    }
    
    func stopDownload() {
        // Stop any active downloads when video view disappears
        playerManager.stopCurrentDownload()
        print("🛑 Stopped download for \(url.lastPathComponent)")
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        statusObserver?.invalidate()
        playerManager.clearResourceLoaders()
        print("♻️ VideoPlayerViewModel deinitialized")
    }
}
