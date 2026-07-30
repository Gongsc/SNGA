import SwiftUI

struct BottomActionBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .buttonStyle(ActionButtonStyle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .overlay(alignment: .top) {
                Divider()
            }
    }

    private struct ActionButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            ActionButton(configuration: configuration)
        }
    }

    private struct ActionButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.sngaTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: ActionButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 4)
                .frame(minWidth: 26, minHeight: 26)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(borderColor)
                }
                .contentShape(.rect)
                .scaleEffect(
                    configuration.isPressed && isEnabled && !reduceMotion ? 0.96 : 1
                )
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.08),
                    value: configuration.isPressed
                )
        }

        private var backgroundColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed {
                return theme.accentColor.opacity(0.25)
            }
            if isHovered {
                return theme.accentColor.opacity(0.14)
            }
            return .clear
        }

        private var borderColor: Color {
            guard isEnabled, isHovered || configuration.isPressed else { return .clear }
            return theme.accentColor.opacity(configuration.isPressed ? 0.55 : 0.32)
        }
    }
}
