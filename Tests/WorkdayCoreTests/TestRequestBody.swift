import Foundation

extension URLRequest {
  var testBody: Data {
    // URLSession may pass an upload body as an input stream to URLProtocol.
    var body = httpBody ?? Data()
    if body.isEmpty, let stream = httpBodyStream {
      stream.open()
      defer { stream.close() }
      var buffer = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(contentsOf: buffer.prefix(n))
      }
    }
    return body
  }
}
