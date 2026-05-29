import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlayerViewModel()
    @EnvironmentObject private var pointsStore: PointsStore
    @EnvironmentObject private var episodeStore: EpisodeStore
    @State private var showEditor = false
    @State private var showSignIn = false
    @State private var showRewardsStore = false

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
            .sheet(isPresented: $showRewardsStore) {
                RewardsStoreView()
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
                    showRewardsStore = true
                }
                .buttonStyle(AgoraOutlineButtonStyle())
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct RewardItem: Identifiable {
    let id: String
    let title: String
    let pointsCost: Int
    let description: String
}

private struct RewardsStoreView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pointsStore: PointsStore
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showInsufficientPointsSubtext = false

    private let socksReward = RewardItem(
        id: "embroidered-socks",
        title: "Embroidered Agora Socks",
        pointsCost: 1_000,
        description: "A pair of embroidered socks. Shipping is included."
    )

    var body: some View {
        NavigationView {
            ZStack {
                AgoraBackgroundView()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        AgoraCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Rewards Store")
                                    .font(AgoraTheme.cardTitleFont)
                                    .foregroundColor(AgoraTheme.ink)

                                Text("Trade your Agora Points for rewards.")
                                    .font(AgoraTheme.tagFont)
                                    .foregroundColor(AgoraTheme.inkMuted)

                                Text("\(pointsStore.totalPoints) points available")
                                    .font(AgoraTheme.cardValueFont)
                                    .foregroundColor(AgoraTheme.ink)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        AgoraCard {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(socksReward.title)
                                        .font(AgoraTheme.cardTitleFont)
                                        .foregroundColor(AgoraTheme.ink)
                                    Spacer()
                                    AgoraTag(text: "\(socksReward.pointsCost) pts")
                                }

                                Text(socksReward.description)
                                    .font(AgoraTheme.bodyFont)
                                    .foregroundColor(AgoraTheme.inkMuted)

                                if !pointsStore.isEnabled {
                                    Text("Sign in to redeem rewards.")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                } else if showInsufficientPointsSubtext && pointsStore.totalPoints < socksReward.pointsCost {
                                    let available = max(pointsStore.totalPoints, 0)
                                    let needed = socksReward.pointsCost
                                    let missing = max(0, needed - available)
                                    Text("You have \(available) points. You need \(needed) points (\(missing) more).")
                                        .font(AgoraTheme.tagFont)
                                        .foregroundColor(AgoraTheme.inkMuted)
                                }

                                Button("Redeem for \(socksReward.pointsCost) points") {
                                    redeemSocks()
                                }
                                .buttonStyle(AgoraPillButtonStyle())
                                .disabled(!pointsStore.isEnabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Store")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .alert("Redeem Reward", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func redeemSocks() {
        guard pointsStore.isEnabled else {
            showInsufficientPointsSubtext = false
            alertMessage = "Please sign in to redeem rewards."
            showAlert = true
            return
        }

        if pointsStore.redeem(points: socksReward.pointsCost) {
            showInsufficientPointsSubtext = false
            alertMessage = "Redeemed: \(socksReward.title). Shipping is included."
        } else {
            showInsufficientPointsSubtext = true
            let missing = max(0, socksReward.pointsCost - pointsStore.totalPoints)
            alertMessage = "Not enough points yet. You need \(missing) more points."
        }
        showAlert = true
    }
}

#Preview {
    ContentView()
        .environmentObject(PointsStore())
        .environmentObject(EpisodeStore())
}
