import SwiftUI

enum AgoraTheme {
    static let background = LinearGradient(
        gradient: Gradient(colors: [parchment, sand, cloud]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let orbGradient = RadialGradient(
        gradient: Gradient(colors: [bronze.opacity(0.45), .clear]),
        center: .center,
        startRadius: 10,
        endRadius: 150
    )

    static let waveGradient = LinearGradient(
        gradient: Gradient(colors: [lapis.opacity(0.18), .clear]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardGradient = LinearGradient(
        gradient: Gradient(colors: [cardSurface, cardSurface.opacity(0.92)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let accentGradient = LinearGradient(
        gradient: Gradient(colors: [bronze, terracotta]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let cardStroke = Color.white.opacity(0.6)
    static let cardSurface = Color(red: 0.99, green: 0.98, blue: 0.96)
    static let tagBackground = Color.white.opacity(0.7)

    static let ink = obsidian
    static let inkMuted = obsidianMuted
    static let inkOnAccent = Color.white
    static let accent = bronze
    static let shadow = Color.black.opacity(0.15)

    static let titleFont = Font.custom("IowanOldStyle-Bold", size: 30)
    static let subtitleFont = Font.custom("IowanOldStyle-Italic", size: 16)
    static let cardTitleFont = Font.custom("AvenirNext-DemiBold", size: 16)
    static let cardValueFont = Font.custom("AvenirNext-DemiBold", size: 22)
    static let bodyFont = Font.custom("AvenirNext-Regular", size: 16)
    static let buttonFont = Font.custom("AvenirNext-DemiBold", size: 14)
    static let tagFont = Font.custom("AvenirNext-Medium", size: 11)

    struct PrimaryButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(AgoraTheme.buttonFont)
                .foregroundColor(AgoraTheme.inkOnAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(AgoraTheme.accentGradient)
                )
                .opacity(configuration.isPressed ? 0.85 : 1.0)
        }
    }

    private static let parchment = Color(red: 0.98, green: 0.96, blue: 0.92)
    private static let sand = Color(red: 0.94, green: 0.91, blue: 0.86)
    private static let cloud = Color(red: 0.97, green: 0.97, blue: 0.98)
    private static let obsidian = Color(red: 0.15, green: 0.16, blue: 0.18)
    private static let obsidianMuted = Color(red: 0.33, green: 0.34, blue: 0.36)
    private static let bronze = Color(red: 0.77, green: 0.55, blue: 0.24)
    private static let terracotta = Color(red: 0.74, green: 0.33, blue: 0.23)
    private static let lapis = Color(red: 0.16, green: 0.30, blue: 0.55)
}
