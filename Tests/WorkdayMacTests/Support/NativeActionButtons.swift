import AppKit

/// Locate the native recovery controls without depending on other SwiftUI button layouts.
@MainActor func nativeActionButtons(in root: NSView) -> [NSButton] {
  if let button = root as? NSButton { return [button] }
  return root.subviews.flatMap { nativeActionButtons(in: $0) }
}
