import SwiftUI

struct InteractivePromptView: View {
    let prompt: Prompt
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var pointsStore: PointsStore

    var body: some View {
        AgoraCard {
            VStack(spacing: 16) {
                HStack {
                    Text("Agora Check-In")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    Spacer()

                    AgoraTag(text: "Live")
                }

                Text(prompt.question)
                    .font(AgoraTheme.bodyFont)
                    .foregroundColor(AgoraTheme.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Response")
                        .font(AgoraTheme.tagFont)
                        .foregroundColor(AgoraTheme.inkMuted)

                    TextEditor(text: $viewModel.answerText)
                        .frame(height: 120)
                        .padding(10)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(AgoraTheme.cardStroke, lineWidth: 1)
                        )
                }

                if viewModel.drivingModeEnabled {
                    VStack(spacing: 10) {
                        if !viewModel.drivingStatusText.isEmpty {
                            Text(viewModel.drivingStatusText)
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        Button {
                            viewModel.drivingMicTapped()
                        } label: {
                            Image(systemName: viewModel.speechManager.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 34, weight: .bold))
                                .foregroundColor(AgoraTheme.inkOnAccent)
                                .frame(width: 110, height: 110)
                                .background(Circle().fill(AgoraTheme.accentGradient))
                                .shadow(color: AgoraTheme.shadow, radius: 10, x: 0, y: 6)
                        }
                        .accessibilityLabel(viewModel.speechManager.isRecording ? "Stop recording" : "Start recording")
                    }
                } else {
                    HStack(spacing: 12) {
                        Button(viewModel.speechManager.isRecording ? "Stop" : "Speak") {
                            viewModel.toggleRecording()
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())

                        Button("Use Transcript") {
                            viewModel.answerText = viewModel.speechManager.transcript
                        }
                        .buttonStyle(AgoraOutlineButtonStyle())
                    }
                }

                if viewModel.isEvaluating {
                    ProgressView("Evaluating...")
                        .font(AgoraTheme.bodyFont)
                }

                if !viewModel.feedbackText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Score")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)

                            Spacer()

                            Text("\(viewModel.lastScore)/100")
                                .font(AgoraTheme.cardTitleFont)
                                .foregroundColor(AgoraTheme.ink)
                        }

                        HStack {
                            Text("Grade \(viewModel.lastGrade.rawValue)")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                            Spacer()
                            Text("+\(viewModel.lastAwardedPoints) Agora Points")
                                .font(AgoraTheme.tagFont)
                                .foregroundColor(AgoraTheme.inkMuted)
                        }

                        Text(viewModel.feedbackText)
                            .font(AgoraTheme.bodyFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button("Submit") {
                        Task {
                            await viewModel.submitAnswer(pointsStore: pointsStore)
                        }
                    }
                    .buttonStyle(AgoraPillButtonStyle())
                    .disabled(viewModel.drivingModeEnabled)

                    Button("Continue") {
                        viewModel.continuePlayback()
                    }
                    .buttonStyle(AgoraOutlineButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .onReceive(viewModel.speechManager.$transcript) { transcript in
            guard viewModel.speechManager.isRecording else { return }
            viewModel.answerText = transcript
        }
    }
}
