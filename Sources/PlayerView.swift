import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @EnvironmentObject private var pointsStore: PointsStore

    var body: some View {
        VStack(spacing: 16) {
            AgoraCard {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Now Playing")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)

                        Text(viewModel.episode.title)
                            .font(AgoraTheme.cardValueFont)
                            .foregroundColor(AgoraTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: 8) {
                        ProgressView(value: viewModel.audioManager.currentTime, total: max(viewModel.audioManager.duration, 1))
                            .tint(AgoraTheme.accent)

                        HStack {
                            Text(formatTime(viewModel.audioManager.currentTime))
                            Spacer()
                            Text(formatTime(viewModel.audioManager.duration))
                        }
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)
                    }

                    HStack(spacing: 16) {
                        Button {
                            viewModel.skip(by: -15)
                        } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }

                        Button {
                            viewModel.togglePlay()
                        } label: {
                            Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    Circle().fill(AgoraTheme.accentGradient)
                                )
                                .foregroundColor(AgoraTheme.inkOnAccent)
                                .shadow(color: AgoraTheme.shadow, radius: 8, x: 0, y: 4)
                        }

                        Button {
                            viewModel.skip(by: 15)
                        } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(
                                    Circle().fill(AgoraTheme.cardSurface)
                                )
                                .foregroundColor(AgoraTheme.ink)
                                .overlay(
                                    Circle().stroke(AgoraTheme.cardStroke, lineWidth: 1)
                                )
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Interactive Mode")
                            .font(AgoraTheme.cardTitleFont)
                            .foregroundColor(AgoraTheme.ink)
                        Text("AI prompts pause the audio for reflection.")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    Spacer()

                    Toggle("", isOn: $viewModel.interactiveModeEnabled)
                        .labelsHidden()
                        .toggleStyle(SwitchToggleStyle(tint: AgoraTheme.accent))
                }
            }
            .padding(.horizontal, 16)

            if viewModel.showPrompt, let prompt = viewModel.activePrompt {
                InteractivePromptView(
                    prompt: prompt,
                    viewModel: viewModel,
                    pointsStore: pointsStore
                )
            }
        }
        .onReceive(viewModel.audioManager.$currentTime) { time in
            viewModel.checkForPrompt(at: time)
        }
        .task {
            _ = await viewModel.speechManager.requestAuthorization()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let intSeconds = Int(seconds)
        let minutes = intSeconds / 60
        let remainingSeconds = intSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}
