//
//  CachedVideoPlayerLegacy.swift
//  VideoDemo
//
//  Legacy sync implementation using PINCache
//  For testing and comparison purposes
//

import SwiftUI
import AVKit
import AVFoundation
import Combine

struct CachedVideoPlayerLegacy: View {
    let url: URL
    @StateObject private var viewModel: VideoPlayerViewModelLegacy
    
    init(url: URL, playerManager: VideoPlayerService, cacheQuery: VideoCacheQuerying) {
        self.url = url
        _viewModel = StateObject(wrappedValue: VideoPlayerViewModelLegacy(url: url, playerManager: playerManager, cacheQuery: cacheQuery))
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

class VideoPlayerViewModelLegacy: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var isCached = false
    @Published var isDownloading = false
    @Published var currentTime: Double?
    @Published var duration: Double?
    
    private let url: URL
    private let playerManager: VideoPlayerService
    private let cacheQuery: VideoCacheQuerying
    private let cacheQueryQueue = DispatchQueue(label: "com.videodemo.cacheQuery.legacy", qos: .userInitiated)
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    
    init(url: URL, playerManager: VideoPlayerService, cacheQuery: VideoCacheQuerying) {
        self.url = url
        self.playerManager = playerManager
        self.cacheQuery = cacheQuery
        setupPlayer()
        checkCacheStatus()
    }
    
    private func setupPlayer() {
        // Check cache status off the main thread
        fetchIsCached { [weak self] cached in
            guard let self = self else { return }
            if cached {
                print("▶️ [Legacy] Playing cached video: \(self.url.lastPathComponent)")
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
                    print("❌ [Legacy] Player item failed: \(item.error?.localizedDescription ?? "unknown")")
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

    private func fetchIsCached(completion: @escaping (Bool) -> Void) {
        // Sync mode: use background queue to avoid blocking main thread
        cacheQueryQueue.async { [weak self] in
            guard let self = self else { return }
            let cached = self.cacheQuery.isCached(url: self.url)
            DispatchQueue.main.async {
                completion(cached)
            }
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
        playerManager.stopCurrentDownload()
        print("🛑 [Legacy] Stopped download for \(url.lastPathComponent)")
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        statusObserver?.invalidate()
        playerManager.clearResourceLoaders()
        print("♻️ [Legacy] VideoPlayerViewModelLegacy deinitialized")
    }
}
