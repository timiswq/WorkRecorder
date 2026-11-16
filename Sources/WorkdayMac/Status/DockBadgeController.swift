import AppKit
import Combine

/// Keeps the device icon, reminder expression and native count in sync without a window.
/// Processing, caption activity and unread-content dots are deliberately not inputs.
@MainActor final class DockBadgeController {
  private let model: AppModel
  private let tile: NSDockTile
  private var subscription: AnyCancellable?
  private(set) var appearance: DockIconAppearance?
  private var stopped = false

  init(model: AppModel, tile: NSDockTile) {
    self.model = model
    self.tile = tile
    let inputs: [AnyPublisher<Void, Never>] = [
      model.$catalog.map { _ in () }.eraseToAnyPublisher(),
      model.$recordings.map { _ in () }.eraseToAnyPublisher(),
      model.$preferences.map(\.boundID).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.card.$state.map { "\($0.connected)|" + $0.phase.rawValue + "|" + ($0.filename ?? "") }
        .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.card.$connectionPhase.map { _ in () }.eraseToAnyPublisher(),
      model.card.$bluetoothBlock.map { _ in () }.eraseToAnyPublisher(),
      // DesktopCompanion owns freshness polling, including the transition to unknown.
      model.desktop.$status.map(\.kind).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.usb.$volumes.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.usb.$excludedStems.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.usb.$activeFilenameUnknown.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
    ]
    // @Published emits before its value is stored. Read after the batch settles,
    // and avoid writing the same Dock label for repeated device polls.
    subscription = Publishers.MergeMany(inputs)
      .debounce(for: .milliseconds(40), scheduler: RunLoop.main)
      .sink { [weak self] in self?.refresh() }
    refresh()
  }

  private func refresh() {
    guard !stopped else { return }
    let label = model.pendingSyncBadgeText
    if tile.badgeLabel != label { tile.badgeLabel = label }
    let next = DockIconAppearance(kind: model.deviceStatus(at: Date()).kind, reminder: label != nil)
    if next != appearance, let image = DockIconArtwork.image(for: next) {
      NSApp.applicationIconImage = image
      appearance = next
    }
  }

  func stop() {
    guard !stopped else { return }
    stopped = true
    subscription?.cancel()
    subscription = nil
    tile.badgeLabel = nil
    // AppKit's named application image mutates when the Dock icon changes. Reset the
    // property instead of retaining that image, which would restore the last state.
    NSApp.applicationIconImage = nil
  }
}
