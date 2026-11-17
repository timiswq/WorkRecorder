import SwiftUI
import WorkdayCore

struct RecordingCardView: View {
  @ObservedObject var model: AppModel
  @ObservedObject var desktop: DesktopCompanion
  @State private var showsDeviceDetails: Bool?

  var body: some View {
    let status = desktop.status
    let busy = model.usesWiFiCard && model.wifiSync.busy
    let action = model.hardwareAction(for: status) ?? (status.canConnect ? .bind : nil)
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        header(status, showSwitch: action != .bind || busy)
        if busy {
          WiFiSyncControls(model: model, onDevicePage: true)
        } else if status.isUSB {
          SyncStatusView(model: model, onDevicePage: true)
        } else {
          recordingStatus(status, action: action)
          if model.usesWiFiCard && status.kind != .idle && !model.wifiSync.result.isEmpty {
            VStack(alignment: .leading, spacing: 6) { WiFiSyncResult(model: model) }
          }
        }
        if model.recorderName != nil && model.card.switchingTo == nil {
          deviceDetails(status)
        }
      }
      .padding(.horizontal, 27).padding(.vertical, 23)
      .frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Palette.surface)
  }

  private func header(_ status: DesktopStatus, showSwitch: Bool) -> some View {
    let name = model.connectedRecorderName
    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 16) {
        Text(name ?? "录音卡").font(.system(size: 26, weight: .semibold))
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
          .accessibilityAddTraits(.isHeader).accessibilityIdentifier("recorder-page-title")
        Spacer(minLength: 0)
        if showSwitch {
          Button(model.recorderName == nil ? "选择设备…" : "切换设备…") { model.showRecorderPicker() }
            .buttonStyle(.link).fixedSize().disabled(!model.canChangeCard)
            .help(model.canChangeCard ? "选择要连接的录音卡" : "当前操作完成后可切换设备")
        }
      }
      if name != nil {
        Text(status.isUSB ? "USB 已连接 · 实时字幕暂停，录音状态请查看卡上指示。" : model.recorderConnectionDetail(status))
          .font(.callout).foregroundStyle(Palette.muted)
      } else if let target = model.card.switchingTo {
        Text("正在验证 \(target.name) 的连接").font(.callout).foregroundStyle(Palette.muted)
      } else if let previous = model.recorderName {
        Text("上次选择 · \(previous)").font(.callout).foregroundStyle(Palette.muted)
      }
      if let error = model.card.selectionError {
        Text(error).font(.callout).foregroundStyle(Palette.amber)
      }
    }
  }

  private func recordingStatus(_ status: DesktopStatus, action: StatusAction?) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: StatusStyle.symbol(status.kind)).font(.system(size: 15))
          .foregroundStyle(StatusStyle.color(status)).accessibilityHidden(true)
        Text(status.canConnect ? "未连接" : status.kind == .idle ? "空闲" : status.displayTitle)
          .font(.system(size: 18, weight: .semibold))
        if let elapsed = status.elapsed {
          Text(WorkdayDate.clock(elapsed)).font(.body.monospacedDigit()).foregroundStyle(Palette.muted)
            .accessibilityLabel("已录 " + WorkdayDate.clock(elapsed))
        }
      }
      Text(instruction(status)).font(.callout).foregroundStyle(Palette.muted)
        .fixedSize(horizontal: false, vertical: true)
      if status.kind == .idle && model.usesWiFiCard {
        WiFiSyncControls(model: model, onDevicePage: true)
      } else if let action {
        Button(action.title) { model.performStatusAction(action) }
          .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 5)
          .disabled(action == .bind && !model.canChangeCard)
          .accessibilityIdentifier("recorder-page-action")
      }
    }
  }

  private func instruction(_ status: DesktopStatus) -> String {
    switch status.kind {
    case .recording: return "在卡上按键暂停或结束录音，保存后可同步。"
    case .idle where !model.usesWiFiCard: return "在卡上按键开始录音。用 USB 数据线连接 Mac，可同步已保存的录音。"
    case .disconnected where status.canConnect && model.recorderName == nil:
      return "选择附近的录音卡，或用 USB 数据线连接设备。"
    default: return status.instruction
    }
  }

  private func deviceDetails(_ status: DesktopStatus) -> some View {
    let volume = model.usesWiFiCard ? nil : model.usb.volumes.first
    let expanded = Binding(
      get: { showsDeviceDetails ?? (model.connectedRecorderName != nil) },
      set: { showsDeviceDetails = $0 })
    return DisclosureGroup("设备详情", isExpanded: expanded) {
      VStack(alignment: .leading, spacing: 12) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
          detail("文件同步", model.usesWiFiCard ? "Wi-Fi 热点" : "USB 数据线")
          if let volume {
            if let space = model.usb.diskSpace {
              detail("磁盘空间", "可用 " + bytes(space.free) + " / 共 " + bytes(space.total))
            }
            if let inventory = model.catalog.snapshots[volume.id], model.inventoryIsFresh {
              detail("卡内录音", (inventory.complete ? "" : "已发现 ") + "\(inventory.entries.count) 段")
            }
          } else if model.card.state.connected {
            if let firmware = model.card.state.firmware, !firmware.isEmpty {
              detail("固件版本", firmware)
            }
            if let free = model.card.state.freeBytes, let total = model.card.state.totalBytes {
              detail("卡内空间", "可用 " + bytes(free) + " / 共 " + bytes(total))
            } else if let fraction = model.card.state.freeStorageFraction {
              detail("卡内空间", availableSpace(fraction))
            }
            if [.recording, .paused, .saving].contains(status.kind),
              let filename = model.card.state.filename, !filename.isEmpty {
              detail("当前文件", filename)
            }
            if let serial = model.card.serial { detail("序列号", serial) }
          }
          if let volume {
            detail("磁盘标识", volume.uuid)
          } else if let id = model.preferences.selectedRecorderID {
            detail("蓝牙标识", id)
          } else if let id = model.preferences.usbOnlyVolumeID {
            detail("磁盘标识", String(id.dropFirst("usb:".count)))
          }
        }
        if (status.kind == .disconnected || status.kind == .unknown),
          let id = model.card.stateDeviceID, id == model.preferences.selectedRecorderID {
          Text(status.detail).foregroundStyle(Palette.muted)
        }
        HStack(spacing: 14) {
          Button("设备设置…") { model.requestSettings(.device) }
          if let volume {
            Button("在访达中查看磁盘") { NSWorkspace.shared.open(volume.url) }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
    }.font(.callout)
  }

  private func detail(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(Palette.muted)
      Text(value).textSelection(.enabled)
    }
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  private func availableSpace(_ fraction: Double) -> String {
    if fraction > 0 && fraction < 0.001 { return "可用不足 0.1%" }
    if fraction > 0.999 && fraction < 1 { return "可用超过 99.9%" }
    return "可用 " + fraction.formatted(.percent.precision(.fractionLength(0...1)))
  }
}
