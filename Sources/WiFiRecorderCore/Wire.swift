import Foundation

public enum WiFiRecorderError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let s) = self { return s }
    return nil
  }
}
public enum Profile: String, Codable {
  case b3085 = "B3085"
  case e8a = "E8A"
  public var service: String { self == .b3085 ? "B0B0" : "E8A0" }
  public var prefix: String { self == .b3085 ? "B0B" : "E8A" }
  public var head: [UInt8] { self == .b3085 ? [0xA0, 0x0A] : [0xE5, 0x5E] }
}
public struct Packet {
  public let key: UInt8
  public let payload: [UInt8]
  public let profile: Profile?
  public init(_ key: UInt8, _ payload: [UInt8], profile: Profile? = nil) {
    self.key = key
    self.payload = payload
    self.profile = profile
  }
}

/// DOWAY 3.8.3 displays the two B3085 key 5 storage counts as decimal MB.
public struct WiFiCardStatus {
  public struct Storage: Equatable, Sendable {
    public let totalBytes: Int64
    public let freeBytes: Int64
    public var freeFraction: Double { Double(freeBytes) / Double(totalBytes) }

    public init?(totalMegabytes: UInt32, freeMegabytes: UInt32) {
      guard totalMegabytes > 0, freeMegabytes <= totalMegabytes else { return nil }
      totalBytes = Int64(totalMegabytes) * 1_000_000
      freeBytes = Int64(freeMegabytes) * 1_000_000
    }
  }

  public let recordingCode: UInt8
  public let battery: Int?
  public let storage: Storage?
  public var freeStorageFraction: Double? { storage?.freeFraction }

  public init?(_ payload: [UInt8]) {
    guard payload.count >= 11 else { return nil }
    storage = Storage(totalMegabytes: UInt32(Wire.be32(payload, 0)),
                      freeMegabytes: UInt32(Wire.be32(payload, 4)))
    battery = payload[9] <= 100 ? Int(payload[9]) : nil
    recordingCode = payload[10]
  }
}

public struct RecordingEntry: Identifiable, Equatable {
  public let wireName: [UInt8]
  public let size: UInt64
  public var id: String { Wire.hex(wireName) }
  public var name: String { String(decoding: wireName.prefix { $0 != 0 }, as: UTF8.self) }
  public var supportsCardCleanup: Bool {
    // FW925 uses a fourteen-digit name for saved recordings.
    wireName.allSatisfy { (48...57).contains($0) }
  }
  public init(_ payload: [UInt8]) throws {
    guard payload.count >= 19, payload[0] == 0 else {
      throw WiFiRecorderError.invalid("文件条目不足19字节")
    }
    wireName = Array(payload[1..<15])
    size = Wire.be32(payload, 15)
    guard wireName.contains(where: { $0 != 0 }) else { throw WiFiRecorderError.invalid("设备返回空文件名") }
  }
}
public struct RecordingList {
  private var entries: [String: RecordingEntry] = [:]

  public init() {}
  public var discoveredCount: Int { entries.count }

  /// Both the hotspot and the Bluetooth control channel use the same list frames.
  public mutating func accept(_ payload: [UInt8]) throws -> [RecordingEntry]? {
    switch payload.first {
    case 0:
      let file = try RecordingEntry(payload)
      if let previous = entries[file.id], previous != file {
        throw WiFiRecorderError.invalid("同一录音在清单中的大小发生变化，请重试")
      }
      entries[file.id] = file
      return nil
    case 2:
      return entries.values.sorted { $0.name > $1.name }
    default:
      throw WiFiRecorderError.invalid("录音卡未返回有效的列表结束标记")
    }
  }
}
public struct HotspotCredentials {
  public let ssid: String
  public let password: String
  public init(_ payload: [UInt8]) throws {
    guard payload.count >= 18 else { throw WiFiRecorderError.invalid("热点信息不足18字节") }
    let field = Array(payload.prefix(10))
    let end = field.firstIndex(of: 0) ?? 10
    guard field[end...].allSatisfy({ $0 == 0 }),
      let name = String(bytes: field.prefix(end), encoding: .utf8),
      !name.trimmingCharacters(in: .whitespaces).isEmpty,
      !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      payload[10..<18].allSatisfy({ (32...126).contains($0) })
    else { throw WiFiRecorderError.invalid("热点凭据字段无效") }
    ssid = name
    password = String(decoding: payload[10..<18], as: UTF8.self)
  }
}
public struct DeviceIdentity {
  public let serial: String
  public static func manufacturer(_ a: [UInt8]) -> Self? {
    guard a.count >= 8, [[0x16, 0x11], [0x24, 0xA7]].contains(Array(a.prefix(2)).map(Int.init))
    else { return nil }
    var sn = Array(a.dropFirst(8))
    while sn.last == 0 { sn.removeLast() }
    guard let text = String(bytes: sn, encoding: .utf8), text.count <= 32,
      text.unicodeScalars.allSatisfy({
        CharacterSet(
          charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        ).contains($0)
      })
    else { return nil }
    return Self(serial: text)
  }
}
public enum Wire {
  public static let wifiHead = Array("XnoteWifiHead  ".utf8)
  public static let wifiTail = Array("XnoteWifiTail   ".utf8)
  public static func crc(_ a: some Sequence<UInt8>) -> UInt16 {
    var c: UInt16 = 0
    for b in a {
      c ^= UInt16(b)
      for _ in 0..<8 { c = (c >> 1) ^ (c & 1 == 1 ? 0xA001 : 0) }
    }
    return c
  }
  public static func hex(_ a: some Sequence<UInt8>) -> String {
    a.map { String(format: "%02X", $0) }.joined()
  }
  public static func be32(_ a: [UInt8], _ p: Int) -> UInt64 {
    a[p..<p + 4].reduce(0) { ($0 << 8) | UInt64($1) }
  }
  public static func beBytes(_ value: UInt64) -> [UInt8] {
    [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
  }
  public static func ble(_ profile: Profile, _ key: UInt8, _ payload: [UInt8] = []) -> Data {
    precondition(payload.count <= 255)
    let a = profile.head + [1, key, UInt8(payload.count)] + payload
    let c = crc(a)
    return Data(a + [UInt8(c >> 8), UInt8(c & 255)])
  }
  public static func wifi(_ key: UInt8, _ payload: [UInt8] = []) -> Data {
    precondition(payload.count <= 1_048_576)
    return Data(wifiHead + [key, 0, 0, 0, 0] + beBytes(UInt64(payload.count)) + payload + wifiTail)
  }
  public static func download(_ file: RecordingEntry, _ offset: UInt64) throws -> [UInt8] {
    guard offset <= file.size, offset <= 0xFFFF_FFFF else {
      throw WiFiRecorderError.invalid("续传偏移超出范围")
    }
    return file.wireName + beBytes(offset)
  }
}
public struct BLEParser {
  private var buffer: [UInt8] = []
  public private(set) var rejectedCRC = 0
  public init() {}
  public mutating func feed(_ data: Data) -> [Packet] {
    buffer += data
    var p = 0
    var out: [Packet] = []
    while buffer.count - p >= 5 {
      let h = Array(buffer[p..<p + 2])
      let profile: Profile?
      if h == [0xA0, 0x0A] {
        profile = .b3085
      } else if h == [0xE5, 0x5E] || h == [0x5E, 0xE5] {
        profile = .e8a
      } else {
        profile = nil
      }
      guard let profile, buffer[p + 2] == 1 else {
        p += 1
        continue
      }
      let n = Int(buffer[p + 4])
      let length = n + 7
      if buffer.count - p < length { break }
      let c = Wire.crc(buffer[p..<p + length - 2])
      let a = UInt16(buffer[p + length - 2])
      let b = UInt16(buffer[p + length - 1])
      guard c == a << 8 | b || c == b << 8 | a else {
        rejectedCRC += 1
        p += length
        continue
      }
      out.append(Packet(buffer[p + 3], Array(buffer[p + 5..<p + 5 + n]), profile: profile))
      p += length
    }
    buffer.removeFirst(p)
    if buffer.count > 8192 { buffer.removeAll() }
    return out
  }
}
public struct TCPParser {
  private var buffer: [UInt8] = []
  public init() {}
  public mutating func feed(_ data: Data) throws -> [Packet] {
    guard buffer.count + data.count <= 2_097_152 else {
      throw WiFiRecorderError.invalid("TCP接收缓冲超过2MiB")
    }
    buffer += data
    var p = 0
    var out: [Packet] = []
    while buffer.count - p >= 24 {
      guard Array(buffer[p..<p + 15]) == Wire.wifiHead else {
        p += 1
        continue
      }
      let n = Int(Wire.be32(buffer, p + 20))
      guard n <= 1_048_576 else { throw WiFiRecorderError.invalid("TCP单帧超过1MiB") }
      let length = n + 40
      if buffer.count - p < length { break }
      guard Array(buffer[p + 24 + n..<p + length]) == Wire.wifiTail else {
        throw WiFiRecorderError.invalid("TCP帧尾错误")
      }
      out.append(Packet(buffer[p + 15], Array(buffer[p + 24..<p + 24 + n])))
      p += length
    }
    buffer.removeFirst(p)
    return out
  }
}
