import SwiftUI

struct SkeletonShimmerView<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShimmering = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .foregroundStyle(shimmerStyle)
            .allowsHitTesting(false)
            .task(id: reduceMotion) {
                isShimmering = false
                guard !reduceMotion else { return }
                await Task.yield()
                isShimmering = true
            }
            .animation(
                reduceMotion
                    ? nil
                    : .linear(duration: 1.35).repeatForever(autoreverses: false),
                value: isShimmering
            )
    }

    private var shimmerStyle: LinearGradient {
        let baseColor = Color.primary.opacity(0.07)
        let highlightColor = Color.primary.opacity(0.16)
        let leadingEdge = reduceMotion
            ? UnitPoint.leading
            : UnitPoint(x: isShimmering ? 1.3 : -1.3, y: 0.5)
        let trailingEdge = reduceMotion
            ? UnitPoint.trailing
            : UnitPoint(x: isShimmering ? 2.3 : -0.3, y: 0.5)

        return LinearGradient(
            colors: [
                baseColor,
                baseColor,
                highlightColor,
                baseColor,
                baseColor
            ],
            startPoint: leadingEdge,
            endPoint: trailingEdge
        )
    }
}
