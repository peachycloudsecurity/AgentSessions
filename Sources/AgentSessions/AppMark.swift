import SwiftUI

/// Green "live" indicator for a session that is currently being written to.
///
/// Deliberately static: a `repeatForever` pulse keeps SwiftUI's animator awake,
/// which drives a full layout pass every frame and costs ~30% CPU while idle.
/// A soft halo reads as "live" for free.
struct ActivityDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Theme.result)
            .frame(width: size, height: size)
            .shadow(color: Theme.result.opacity(0.7), radius: size * 0.6)
    }
}

/// The app's mark: three offset cards, i.e. a stack of past sessions.
///
/// Vendor-neutral on purpose — this app reads transcripts from several coding
/// agents, so its identity must not borrow any one of their marks.
struct StackMark: View {
    /// Back-to-front, as (xOffset, yOffset, widthScale) in unit space.
    private static let cards: [(CGFloat, CGFloat, CGFloat)] = [
        (0.18, -0.26, 0.64),
        (0.09, -0.13, 0.82),
        (0.00,  0.00, 1.00),
    ]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cardHeight = side * 0.46
            let radius = side * 0.13

            ZStack {
                ForEach(Array(Self.cards.enumerated()), id: \.offset) { index, card in
                    let width = side * card.2
                    RoundedRectangle(cornerRadius: radius)
                        .fill(.primary.opacity(index == Self.cards.count - 1 ? 1 : 0.45))
                        .frame(width: width, height: cardHeight)
                        .offset(x: side * card.0 * 0.5, y: side * card.1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Small coloured monogram identifying which coding agent a session came from.
struct AgentBadge: View {
    let letter: String
    let colors: [Color]
    var size: CGFloat = 38
    var isSelected: Bool = true

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26)
            .fill(
                LinearGradient(
                    colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay(
                Text(letter)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.26)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1)
            )
            .opacity(isSelected ? 1 : 0.45)
            .saturation(isSelected ? 1 : 0.2)
    }
}
