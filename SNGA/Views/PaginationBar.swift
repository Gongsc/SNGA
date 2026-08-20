import SwiftUI

/// 话题列表和话题共用的底部分页条。
///
/// 原先两边各有一份几乎逐行相同的实现（各约 130 行），差别只在无障碍标识前缀和
/// 提示语措辞。合成一份之后，翻页行为只有一处可改。
///
/// 版式上，翻页键两两收进分段控件：原先首页、上一页、页码框、总页数、跳转、
/// 下一页、尾页七个控件等权重平铺在一条 30 点高的栏里，边界只靠间距分辨；
/// 分组之后「往回翻」和「往前翻」各自成块，页码夹在中间，扫一眼就分得清。
///
/// 右侧的 `actions` 不进分段控件 —— 各调用点传进来的既有 `Button`，也有 `Menu`
/// 和挂着 popover 的按钮，`Menu` 不吃 `buttonStyle`，塞进托盘只会样式打架。
/// 它们仍旧由 `BottomActionBar` 统一上样式，靠中间的 `Spacer` 和翻页组分开。
struct PaginationBar<Actions: View>: View {
    @Environment(\.sngaTheme) private var theme

    let currentPage: Int
    let totalPages: Int
    let isLoading: Bool
    var showsLoadingIndicator = true
    /// 只有一页时是否整组藏起来。话题列表藏，话题不藏 —— 保持两边原有的行为。
    var hidesControlsOnSinglePage = false
    /// 无障碍标识前缀，如 `topic-list`、`thread`。
    let identifierPrefix: String
    /// 提示语里的主语，如「话题列表」「本话题」。
    let subject: String
    var navigate: (Int) -> Void
    let actions: Actions

    @State private var pageText = "1"
    @State private var isHoveringPageField = false
    @FocusState private var isEditingPage: Bool

    init(
        currentPage: Int,
        totalPages: Int,
        isLoading: Bool,
        showsLoadingIndicator: Bool = true,
        hidesControlsOnSinglePage: Bool = false,
        identifierPrefix: String,
        subject: String,
        navigate: @escaping (Int) -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.currentPage = currentPage
        self.totalPages = totalPages
        self.isLoading = isLoading
        self.showsLoadingIndicator = showsLoadingIndicator
        self.hidesControlsOnSinglePage = hidesControlsOnSinglePage
        self.identifierPrefix = identifierPrefix
        self.subject = subject
        self.navigate = navigate
        self.actions = actions()
    }

    var body: some View {
        BottomActionBar {
            HStack(spacing: 8) {
                if showsControls {
                    ViewThatFits(in: .horizontal) {
                        controls(isCompact: false)
                        controls(isCompact: true)
                    }
                }

                if isLoading && showsLoadingIndicator {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在加载\(subject)")
                        .accessibilityIdentifier("\(identifierPrefix)-loading-indicator")
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    actions
                }
                .fixedSize()
            }
        }
        .onAppear {
            pageText = String(currentPage)
        }
        .onChange(of: currentPage) { _, newValue in
            pageText = String(newValue)
        }
        .onChange(of: totalPages) { _, newValue in
            if let value = Int(pageText), value > newValue {
                pageText = String(newValue)
            }
        }
    }

    private var showsControls: Bool {
        hidesControlsOnSinglePage ? totalPages > 1 : true
    }

    private func controls(isCompact: Bool) -> some View {
        HStack(spacing: 6) {
            PaginationSegments {
                Button("首页", systemImage: "backward.end.fill") {
                    navigate(1)
                }
                .labelStyle(.iconOnly)
                .help("跳转到\(subject)首页")
                .accessibilityIdentifier("\(identifierPrefix)-first-page")
                .disabled(isLoading || currentPage <= 1)

                Button("上一页", systemImage: "chevron.left") {
                    navigate(currentPage - 1)
                }
                .labelStyle(.iconOnly)
                .help("\(subject)上一页")
                .accessibilityIdentifier("\(identifierPrefix)-previous-page")
                .disabled(isLoading || currentPage <= 1)
            }

            pageIndicator(isCompact: isCompact)

            PaginationSegments {
                Button("下一页", systemImage: "chevron.right") {
                    navigate(currentPage + 1)
                }
                .labelStyle(.iconOnly)
                .help("\(subject)下一页")
                .accessibilityIdentifier("\(identifierPrefix)-next-page")
                .disabled(isLoading || currentPage >= totalPages)

                Button("尾页", systemImage: "forward.end.fill") {
                    navigate(totalPages)
                }
                .labelStyle(.iconOnly)
                .help("跳转到\(subject)尾页")
                .accessibilityIdentifier("\(identifierPrefix)-last-page")
                .disabled(isLoading || currentPage >= totalPages)
            }
        }
        .fixedSize()
    }

    /// 页码本身就是输入框，只是没画边框 —— 平时读起来是一行字，鼠标移上去才
    /// 显出底色，点进去是带焦点环的输入态。原先那个常驻的「跳转」按钮因此去掉，
    /// 回车即跳转（提示语里写明了）。
    private func pageIndicator(isCompact: Bool) -> some View {
        HStack(spacing: 4) {
            TextField("页码", text: $pageText)
                .textFieldStyle(.plain)
                .font(.callout.monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($isEditingPage)
                .onSubmit(performJump)
                .frame(width: pageFieldWidth)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(pageFieldFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(
                                    isEditingPage ? theme.accentColor.opacity(0.6) : .clear
                                )
                        }
                }
                .onHover { isHoveringPageField = $0 }
                .help("输入页码后按回车跳转到\(subject)对应页")
                .accessibilityLabel("\(subject)目标页码")
                .accessibilityIdentifier("\(identifierPrefix)-page-field")

            if !isCompact {
                Text("/ \(totalPages.formatted(.number.grouping(.automatic)))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("共 \(totalPages) 页")
            }
        }
    }

    private var pageFieldFill: Color {
        if isEditingPage { return theme.accentColor.opacity(0.14) }
        if isHoveringPageField { return theme.accentColor.opacity(0.08) }
        return .clear
    }

    /// 宽度跟着总页数的位数走：六位数的版面和一页的话题用同一个宽度，
    /// 要么撑不下，要么在窄栏里白占地方。
    private var pageFieldWidth: CGFloat {
        let digits = max(String(max(totalPages, 1)).count, 2)
        return CGFloat(digits) * 9 + 8
    }

    private var parsedPage: Int? {
        guard let value = Int(pageText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...totalPages).contains(value) else {
            return nil
        }
        return value
    }

    private func performJump() {
        guard let parsedPage, parsedPage != currentPage, !isLoading else {
            pageText = String(currentPage)
            return
        }
        navigate(parsedPage)
    }
}

/// 底栏里的一组按钮：共享一层浅托底，读起来是一块，而不是几个各自为政的图标。
///
/// 按钮平时透明，只有悬停和按下才上色 —— 托底负责「这几个是一类」，
/// 高亮负责「鼠标在哪个上面」，两件事不互相干扰。
///
/// 托底用 `.quaternary` 而不是主题前景色叠透明：整条底栏是 `.regularMaterial`，
/// 半透明色压在材质上算出来是多少全看背后是什么内容，深色主题下经常淡到看不见。
/// 语义色和材质是同一套，明暗跟着窗口的 `preferredColorScheme` 走 —— 那个值本来
/// 就是主题给的，所以六套主题下都对。悬停和按下仍旧用主题强调色。
struct PaginationSegments<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .buttonStyle(SegmentButtonStyle())
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
        }
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SegmentButton(configuration: configuration)
    }

    private struct SegmentButton: View {
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.sngaTheme) private var theme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        let configuration: SegmentButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minWidth: 26, minHeight: 22)
                .background(fillColor, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(.rect)
                .scaleEffect(
                    configuration.isPressed && isEnabled && !reduceMotion ? 0.94 : 1
                )
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isHovered)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.08),
                    value: configuration.isPressed
                )
        }

        private var fillColor: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return theme.accentColor.opacity(0.32) }
            if isHovered { return theme.accentColor.opacity(0.18) }
            return .clear
        }
    }
}
