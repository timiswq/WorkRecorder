import AVFoundation
import Combine
import CoreAudio
import WorkdayCore

/// Owns only the transient local recognition and level meter used by microphone bubbles.
@MainActor final class MicrophoneCaptions: ObservableObject {
  typealias Samples = AsyncThrowingStream<Data, Error>
  let preview: LivePreview
  let meter = LiveAudioMeter(input: .microphonePCM)
  private let open: () async throws -> Samples
  private var task: Task<Void, Never>?
  @Published private(set) var failure: String?
  private(set) var enabled = false

  init(preview: LivePreview? = nil, open: @escaping () async throws -> Samples = MacMicrophone.open) {
    self.preview = preview ?? .local(input: .microphonePCM)
    self.open = open
  }

  func configure(enabled: Bool) {
    guard enabled != self.enabled else { return }
    self.enabled = enabled
    task?.cancel()
    task = nil
    failure = nil
    meter.reset()
    preview.configure(enabled: enabled, service: nil)
    preview.reset()
    guard enabled else { return }
    task = Task { [weak self, open] in
      do {
        let samples = try await open()
        for try await data in samples {
          guard !Task.isCancelled, let self else { return }
          meter.append(data, offset: preview.receivedBytes)
          preview.append(data)
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        preview.reset()
        meter.reset()
        failure = error.localizedDescription
      }
    }
  }

  func retry() {
    guard enabled else { return }
    configure(enabled: false)
    configure(enabled: true)
  }
}

/// AVCapture picks the physical built-in input even if the system default is a headset.
/// All blocking capture-session operations run on the same serial queue.
private final class MacMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "WorkRecorder.microphone.capture", qos: .userInitiated)
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioDataOutput()
  private var observers: [NSObjectProtocol] = []
  private let sink: MicrophoneCaptions.Samples.Continuation

  private init(sink: MicrophoneCaptions.Samples.Continuation) { self.sink = sink }

  static func open() async throws -> MicrophoneCaptions.Samples {
    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
    try Task.checkCancellation()
    guard allowed else {
      throw WorkdayError.invalid("请在「系统设置 → 隐私与安全性 → 麦克风」允许工作留声使用麦克风。")
    }
    return MicrophoneCaptions.Samples(bufferingPolicy: .bufferingNewest(32)) { sink in
      let capture = MacMicrophone(sink: sink)
      capture.queue.async { capture.start() }
      sink.onTermination = { _ in capture.queue.async { capture.stop() } }
    }
  }

  private func start() {
    do {
      let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
      guard let device = devices.first(where: { UInt32(bitPattern: $0.transportType) == kAudioDeviceTransportTypeBuiltIn })
      else { throw WorkdayError.invalid("这台 Mac 没有可用的内置麦克风。") }
      let input = try AVCaptureDeviceInput(device: device)
      guard session.canAddInput(input) else { throw WorkdayError.invalid("无法连接 Mac 内置麦克风。") }
      session.addInput(input)
      guard session.canAddOutput(output) else { throw WorkdayError.invalid("无法读取 Mac 麦克风音频。") }
      session.addOutput(output)
      output.audioSettings = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
      ]
      output.setSampleBufferDelegate(self, queue: queue)
      let center = NotificationCenter.default
      observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) {
        [weak self] note in
        self?.sink.finish(throwing: note.userInfo?[AVCaptureSessionErrorKey] as? Error
          ?? WorkdayError.invalid("Mac 麦克风采集已中断。"))
      })
      observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) {
        [weak self] _ in self?.sink.finish(throwing: WorkdayError.invalid("Mac 麦克风已断开。"))
      })
      session.startRunning()
      if !session.isRunning { throw WorkdayError.invalid("Mac 麦克风未能启动。") }
    } catch { sink.finish(throwing: error) }
  }

  private func stop() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    output.setSampleBufferDelegate(nil, queue: nil)
    if session.isRunning { session.stopRunning() }
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
          format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 16_000,
          format.mChannelsPerFrame == 1, format.mBytesPerFrame == 2, format.mBitsPerChannel == 16,
          format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
          format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
          let block = CMSampleBufferGetDataBuffer(sampleBuffer),
          block.dataLength == CMSampleBufferGetNumSamples(sampleBuffer) * 2 else {
      sink.finish(throwing: WorkdayError.invalid("Mac 麦克风未提供所需的单声道音频格式。"))
      return
    }
    var data = Data(count: block.dataLength)
    let status = data.withUnsafeMutableBytes { bytes in
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
    }
    guard status == noErr else { sink.finish(throwing: WorkdayError.invalid("无法读取麦克风采样。")); return }
    if case .dropped = sink.yield(data) { sink.finish(throwing: WorkdayError.invalid("麦克风音频处理积压，请重试。")) }
  }
}
