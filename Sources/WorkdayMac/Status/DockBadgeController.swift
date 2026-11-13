import AppKit
import Combine

/// Mirrors the sidebar's quantity badge even with every window closed.
/// Processing, caption activity and unread-content dots are deliberately not inputs.
@MainActor final class DockBadgeController {
  private let model: AppModel
  private let tile: NSDockTile
  private var subscription: AnyCancellable?

  init(model: AppModel, tile: NSDockTile) {
    self.model = model
    self.tile = tile
    let inputs: [AnyPublisher<Void, Never>] = [
      model.$catalog.map { _ in () }.eraseToAnyPublisher(),
      model.$recordings.map { _ in () }.eraseToAnyPublisher(),
      model.$preferences.map(\.boundID).removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
      model.card.$state.map { $0.phase.rawValue + "|" + ($0.filename ?? "") }
        .removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
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
    let label = model.pendingSyncBadgeText
    if tile.badgeLabel != label { tile.badgeLabel = label }
  }

  func stop() {
    subscription?.cancel()
    subscription = nil
    tile.badgeLabel = nil
  }
}
