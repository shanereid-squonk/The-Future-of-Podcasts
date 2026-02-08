import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @EnvironmentObject private var pointsStore: PointsStore
    @EnvironmentObject private var episodeStore: EpisodeStore
    @State private var showEditor = false
    @State private var showSignIn = false

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        header

                        PlayerView(viewModel: viewModel)
                            .padding(.horizontal, 16)

                        Button("Edit Episode & Prompts") {
                            showEditor = true
                        }
                        .buttonStyle(AgoraPillButtonStyle())
                        .padding(.horizontal, 16)

                        if !pointsStore.isEnabled {
                            Button("Sign in to collect Agora Points") {
                                showSignIn = true
                            }
                            .buttonStyle(AgoraPillButtonStyle())
                            .padding(.horizontal, 16)
                        } else {
                            Button("Sign Out") {
                                pointsStore.signOut()
                            }
                            .buttonStyle(AgoraOutlineButtonStyle())
                            .padding(.horizontal, 16)
                        }

                        pointsCard
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showEditor) {
                ScrollView {
                    PromptEditorView(episodeStore: episodeStore)
                        .padding(.vertical, 24)
                }
                .background(AgoraBackgroundView())
                .onDisappear {
                    viewModel.updateEpisode(episodeStore.episode)
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInView()
                    .environmentObject(pointsStore)
            }
            .onAppear {
                viewModel.updateEpisode(episodeStore.episode)
                pointsStore.restoreLastUser()
            }
            .onReceive(NotificationCenter.default.publisher(for: .audioDurationUpdated)) { notification in
                if let duration = notification.userInfo?["duration"] as? Double {
                    PlayerDurationCache.shared.duration = duration
                }
            }
            .onReceive(episodeStore.$episode) { updated in
                // Reset duration cache and reload the player with the new URL
                PlayerDurationCache.shared.duration = 0
                viewModel.updateEpisode(updated)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("THE AGORA LA")
                    .font(AgoraTheme.titleFont)
                    .foregroundColor(AgoraTheme.ink)

                AgoraTag(text: "Interactive")
            }
        }
        .padding(.horizontal, 20)
    }

    private var pointsCard: some View {
        AgoraCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agora Points")
                        .font(AgoraTheme.cardTitleFont)
                        .foregroundColor(AgoraTheme.ink)

                    if pointsStore.isEnabled {
                        Text("Signed in as \(UserDefaults.standard.string(forKey: "TheAgoraLA.Auth.UserID") ?? "")")
                            .font(AgoraTheme.tagFont)
                            .foregroundColor(AgoraTheme.inkMuted)
                    }

                    Text("\(pointsStore.totalPoints)")
                        .font(AgoraTheme.cardValueFont)
                        .foregroundColor(AgoraTheme.ink)
                }

                Spacer()

                Button("Redeem") {
                    // Placeholder for future redemption flow
                }
                .buttonStyle(AgoraOutlineButtonStyle())
            }
        }
        .padding(.horizontal, 16)
    }
}

#Preview {
    ContentView()
        .environmentObject(PointsStore())
        .environmentObject(EpisodeStore())
}
