import AppKit
import SwiftUI

/// 系统原生毛玻璃（`NSVisualEffectView`）。
///
/// 为什么不用 SwiftUI 的 `.regularMaterial`：SwiftUI 的 Material 只能采样**窗口内部**的内容，
/// 我们预览区底色是纯白，于是采出来就是一片灰 —— 而 Finder / SF Symbols 的工具栏用的是
/// AppKit 的 `NSVisualEffectView`，配合 `blendingMode` 能采样窗口背后的内容，才是那种通透感。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
