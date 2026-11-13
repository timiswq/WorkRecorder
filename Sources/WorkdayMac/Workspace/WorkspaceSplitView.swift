import AppKit
import SwiftUI

/// A narrow AppKit boundary gives both workspaces the same native divider and minimum pane sizes.
struct WorkspaceSplitView<Leading: View, Trailing: View>: NSViewControllerRepresentable {
  @Environment(\.colorScheme) private var colorScheme
  let minimumLeading: CGFloat
  let minimumTrailing: CGFloat
  let leading: Leading
  let trailing: Trailing

  init(
    minimumLeading: CGFloat = 320, minimumTrailing: CGFloat = 320,
    @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
  ) {
    self.minimumLeading = minimumLeading
    self.minimumTrailing = minimumTrailing
    self.leading = leading()
    self.trailing = trailing()
  }

  func makeNSViewController(context: Context) -> WorkspaceSplitController {
    let controller = WorkspaceSplitController()
    controller.splitView.isVertical = true
    controller.splitView.dividerStyle = .thin
    for (view, minimum) in [(pane(leading), minimumLeading), (pane(trailing), minimumTrailing)] {
      let host = NSHostingController(rootView: view)
      host.sizingOptions = []
      let item = NSSplitViewItem(viewController: host)
      item.minimumThickness = minimum
      item.canCollapse = false
      controller.addSplitViewItem(item)
    }
    return controller
  }

  func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
    (controller.splitViewItems[0].viewController as? NSHostingController<AnyView>)?.rootView = pane(
      leading)
    (controller.splitViewItems[1].viewController as? NSHostingController<AnyView>)?.rootView = pane(
      trailing)
  }

  private func pane<V: View>(_ content: V) -> AnyView {
    AnyView(
      content.environment(\.colorScheme, colorScheme).foregroundStyle(Palette.text).tint(
        Palette.accent))
  }
}

final class WorkspaceSplitController: NSSplitViewController {
  private var hasInitialPosition = false

  override func viewDidLayout() {
    super.viewDidLayout()
    guard !hasInitialPosition, splitView.bounds.width >= 640 else { return }
    hasInitialPosition = true
    splitView.setPosition(splitView.bounds.width * 0.46, ofDividerAt: 0)
  }
}
