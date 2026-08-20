import SwiftUI

struct SkeletonShimmerView<Content: View>: View {
    @Environment(\.sngaTheme) private var theme
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
        // 骨架屏铺在卡片上，两档色就取卡片自己的填充和悬停底 —— 原先写死
        // `Color.primary.opacity(...)`，暖金主题下会在暖色卡片上扫过一道灰。
        let baseColor = theme.fillColor
        let highlightColor = theme.hoverFillColor
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
