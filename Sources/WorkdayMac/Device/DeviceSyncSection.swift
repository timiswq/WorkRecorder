import SwiftUI
import WorkdayCore

enum DeviceTransferMethod: String {
  case wifi = "Wi-Fi 热点"
  case usb = "USB 数据线"
}

struct DeviceSyncSection<Actions: View>: View {
  let title: String
  let method: DeviceTransferMethod
  var transfer: DeviceSyncTransfer?
  var hint: String?
  var showsSpinner = false
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        if showsSpinner {
          ProgressView().controlSize(.small).accessibilityHidden(true)
        }
        Text(title).font(.system(size: 18, weight: .semibold)).accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
        if transfer != nil {
          Text(method.rawValue).foregroundStyle(Palette.muted).fixedSize()
        }
      }
      if let transfer {
        DeviceTransferDetails(transfer: transfer)
      }
      if let hint {
        Text(hint).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      }
      actions()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

struct DeviceTransferDetails: View {
  let transfer: DeviceSyncTransfer

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          position
          Text("·").foregroundStyle(Palette.muted).accessibilityHidden(true)
          filename.fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: 4) {
          position
          filename
        }
      }
      if let progress = transfer.progress, !transfer.stageIsVerifying {
        HStack(spacing: 10) {
          DeviceMeterTrack(fraction: progress.fraction, height: 6)
            .accessibilityLabel("本段录音传输进度")
            .accessibilityValue(percent(progress))
          Text(percent(progress)).monospacedDigit().frame(width: 44, alignment: .trailing)
            .accessibilityHidden(true)
        }
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
              byteCount(progress).fixedSize()
              Spacer(minLength: 0)
              speed(progress)
            }
            VStack(alignment: .leading, spacing: 4) {
              byteCount(progress)
              speed(progress).frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
          .monospacedDigit()
        }
      } else if transfer.progress == nil {
        Text("测速中…").foregroundStyle(Palette.muted)
      }
    }
  }

  private var position: some View {
    Text(transfer.positionLabel).foregroundStyle(Palette.muted).monospacedDigit().fixedSize()
  }

  private var filename: some View {
    Text(transfer.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
  }

  private func percent(_ progress: TransferProgress) -> String {
    // Reserve 100% for the end of the bytes, independent of percent formatting rounding.
    "\(Int(progress.fraction * 100))%"
  }

  private func byteCount(_ progress: TransferProgress) -> some View {
    Text("已传 \(deviceBytes(progress.copied)) / 共 \(deviceBytes(progress.total))")
      .foregroundStyle(Palette.muted)
  }

  private func speed(_ progress: TransferProgress) -> some View {
    let text = DeviceTransferDetails.speedLabel(progress, at: ProcessInfo.processInfo.systemUptime)
    return Text(text).fixedSize().frame(minWidth: 84, alignment: .trailing)
      .accessibilityLabel("传输速度").accessibilityValue(text)
  }

  static func speedLabel(_ progress: TransferProgress, at uptime: TimeInterval) -> String {
    if uptime - progress.uptime >= 1 { return "0 B/s" }
    guard let rate = progress.recentBytesPerSecond else { return "测速中…" }
    return deviceBytes(Int64(max(0, rate))) + "/s"
  }
}

struct DeviceMeterTrack: View {
  let fraction: Double
  let height: CGFloat

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(Palette.line)
        Capsule().fill(Palette.accent)
          .frame(width: geometry.size.width * min(1, max(0, fraction)))
      }
    }.frame(height: height)
  }
}

func deviceBytes(_ value: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  formatter.zeroPadsFractionDigits = true
  formatter.allowsNonnumericFormatting = false
  return formatter.string(fromByteCount: value)
}

struct DeviceSyncResultLines: View {
  let result: DeviceSyncOutcome

  var body: some View {
    if let copies = result.copies {
      Text(copies).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
    if let notice = result.notice {
      Text(notice).foregroundStyle(Palette.amber)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    if let network = result.network {
      Text(network).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct DevicePagePrimaryButton: View {
  let title: String
  let action: () -> Void

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(title).frame(minWidth: 66)
    }
    .buttonStyle(.borderedProminent).controlSize(.large)
  }
}
