import Foundation

/// 同一连接的命令按入队顺序提交。有响应写等待 GATT 回调，无响应写等待系统缓冲可用。
final class RecorderWriter {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private struct Write {
        let payload: [UInt8]
        let raw: Data?
        let inspection: Int?
    }
    private let maximumLength: Int
    private let needsResponse: Bool
    private let canWrite: () -> Bool
    private let submit: (Data) -> Void
    private let schedule: Schedule
    var onWrite: (([UInt8], Data) -> Void)?
    var onWarning: ((String) -> Void)?
    private var queue: [Write] = []
    private var inFlight: Write?
    private var sequence: UInt8 = 0
    private var active = true
    private var flushing = false
    private(set) var inspecting = false
    private var step = 0
    private var generation = 0

    init(maximumLength: Int, needsResponse: Bool, canWrite: @escaping () -> Bool,
         submit: @escaping (Data) -> Void, schedule: @escaping Schedule = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.maximumLength = maximumLength
        self.needsResponse = needsResponse
        self.canWrite = canWrite
        self.submit = submit
        self.schedule = schedule
    }

    func contains(_ payload: [UInt8]) -> Bool { queue.contains { $0.payload == payload } }
    func send(_ payload: [UInt8], acknowledgment: Bool = false) throws {
        guard !payload.isEmpty, payload.count <= Wire.maximumPayloadLength else { throw ProtocolError.invalid("命令长度无效") }
        try enqueue(Write(payload: payload, raw: nil, inspection: nil), acknowledgment: acknowledgment)
    }
    func sendRaw(_ bytes: Data) throws {
        guard !bytes.isEmpty else { throw ProtocolError.invalid("完整帧为空") }
        try enqueue(Write(payload: Array(bytes.dropFirst(Wire.headerLength)), raw: bytes, inspection: nil))
    }
    private func enqueue(_ write: Write, acknowledgment: Bool = false) throws {
        guard active else { throw ProtocolError.invalid("蓝牙会话已经关闭") }
        // 背压时仍接收机身按键确认，保留它与已入队帧的顺序和序号。
        guard acknowledgment || queue.count < 32 else { throw ProtocolError.invalid("蓝牙写入队列已满") }
        guard (write.raw?.count ?? (write.payload.count + Wire.headerLength)) <= maximumLength else {
            throw ProtocolError.invalid("录音卡命令超过单次蓝牙写入长度")
        }
        queue.append(write)
        flush()
    }
    func flush() {
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        while active && !queue.isEmpty && inFlight == nil && canWrite() {
            let write = queue.removeFirst()
            let bytes = write.raw ?? Wire.frame(write.payload, seq: sequence)
            if write.raw == nil { sequence &+= 1 }
            if needsResponse { inFlight = write }
            submit(bytes)
            onWrite?(write.payload, bytes)
            if !needsResponse { advanceInspection(after: write) }
        }
    }
    func wrote(error: Error?) {
        guard active, let write = inFlight else { return }
        inFlight = nil
        if let error {
            if write.inspection == generation { cancelInspection() }
            onWarning?(error.localizedDescription)
        } else { advanceInspection(after: write) }
        flush()
    }
    func inspect() {
        guard active, !inspecting else { return }
        inspecting = true
        step = 0
        nextInspection()
    }
    private func nextInspection() {
        do { try enqueue(Write(payload: RecorderQuery.allCases[step].payload, raw: nil, inspection: generation)) }
        catch { cancelInspection(); onWarning?(error.localizedDescription) }
    }
    private func advanceInspection(after write: Write) {
        guard let expected = write.inspection, inspecting, generation == expected else { return }
        step += 1
        if step == RecorderQuery.allCases.count { inspecting = false; return }
        schedule(0.260) { [weak self] in
            guard let self, self.active, self.inspecting, self.generation == expected else { return }
            self.nextInspection()
        }
    }
    func cancelInspection() {
        // 定时闭包可能已经排入主队列。换代使它不能把旧巡检的下一步写入当前连接。
        generation &+= 1
        queue.removeAll { $0.inspection != nil }
        inspecting = false
    }
    func close() {
        active = false
        cancelInspection()
        queue.removeAll()
        inFlight = nil
    }
}
