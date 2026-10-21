import AppKit
import SwiftUI

/// macOS 26 引入的 Liquid Glass（液态玻璃）材质兼容层。
///
/// 这个 App 最低支持 macOS 14（要能分享给系统版本不同的同事），
/// 所以玻璃效果一律按可用性分支：新系统用真正的 `.glassEffect`，
/// 旧系统退回等价的原生材质（regularMaterial + 细分隔线），
/// 布局与交互完全一致，不会出现"旧系统上控件消失"。
///
/// 已核对的 SDK 签名（MacOSX27.0.sdk，均标注 @available(macOS 26.0, *)）：
///   func glassEffect(_ glass: Glass = .regular, in shape: some Shape) -> some View
///   struct GlassEffectContainer<Content: View>(spacing: CGFloat? = nil, content: () -> Content)
///   struct GlassButtonStyle / GlassProminentButtonStyle（.glass / .glassProminent）
///
/// 注意：不要把 `if let` 套在 `#available` 里面写进 ViewBuilder ——
/// 当前 Swift 编译器会在这种嵌套上崩掉（failed to produce diagnostic）。
/// 所以玻璃参数先在外面算好，分支保持扁平。

@available(macOS 26.0, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint = tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

extension View {

    /// 把控件放进一块液态玻璃里。interactive 打开后悬停/按下会有反应，适合按钮类控件。
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(shape.fill(.regularMaterial))
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    /// 原生玻璃按钮样式：新系统用系统玻璃按钮，旧系统用 bordered
    @ViewBuilder
    func glassButton(_ prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// 应用图标。取运行中 App 的图标，换图标后这里自动跟着变。
struct AppLogoView: View {
    var size: CGFloat = 64

    var body: some View {
        if let logo = NSApp.applicationIconImage {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.47))
                .foregroundStyle(.tint)
        }
    }
}

/// 弹窗右上角的关闭按钮：只留一个 X 图标，不画背景。
///
/// 为什么不给背景：玻璃是半透明的，长什么样取决于背后是什么。弹窗底下没有工具栏
/// 那种带层次的背景可采，自绘圆钮和系统玻璃按钮在纯白/纯深色底上都读不出质感。
/// 既然做不像，就干脆不做 —— 尺寸靠 frame + contentShape 撑出舒适的点击区域。
struct CloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
        .help("关闭")
    }
}

/// 把相邻的玻璃控件放进同一个容器，让它们的玻璃能在视觉上互相融合、靠拢时连成一体。
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat?
    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
