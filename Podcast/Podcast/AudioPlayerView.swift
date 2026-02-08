// Create a SwiftUI view for audio playback controls.
// This basic audio player uses AVFoundation to play a bundled MP3 file.
// The user can play and pause the audio, and see playback progress.

import SwiftUI
import AVFoundation

struct AudioPlayerView: View {
    @StateObject private var audioPlayer = AudioPlayerManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Podcast Episode")
                .font(.title2)
                .bold()

            // Playback controls
            HStack(spacing: 30) {
                Button(action: {
                    audioPlayer.togglePlayPause()
                }) {
                    Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .resizable()
                        .frame(width: 60, height: 60)
                        .foregroundColor(.accentColor)
                }
            }
            
            // Progress bar
            Slider(value: $audioPlayer.currentTime, in: 0...audioPlayer.duration, onEditingChanged: { editing in
                if !editing {
                    audioPlayer.seek(to: audioPlayer.currentTime)
                }
            })
            .disabled(audioPlayer.duration == 0)
            
            // Playback time
            HStack {
                Text(audioPlayer.formattedTime(audioPlayer.currentTime))
                Spacer()
                Text(audioPlayer.formattedTime(audioPlayer.duration))
            }
            .font(.caption)
            .padding(.horizontal)
        }
        .padding()
        .onAppear {
            audioPlayer.loadAudio(named: "Philosophy Bites-Angie Hobbs on Plato on Power.mp3") // Replace with your podcast sample filename
        }
        .onDisappear {
            audioPlayer.stop()
        }
    }
}

class AudioPlayerManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func loadAudio(named fileName: String) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: nil) else { return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            duration = player?.duration ?? 0
            currentTime = 0
            player?.prepareToPlay()
        } catch {
            print("Failed to load audio: \(error)")
        }
    }
    
    func togglePlayPause() {
        guard let player = player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }
    
    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
        currentTime = 0
    }
    
    func seek(to time: Double) {
        player?.currentTime = time
        currentTime = time
    }
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let player = self.player else { return }
            self.currentTime = player.currentTime
            if player.currentTime >= player.duration {
                self.isPlaying = false
                self.stopTimer()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    func formattedTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

#Preview {
    AudioPlayerView()
}

