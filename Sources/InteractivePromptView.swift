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
