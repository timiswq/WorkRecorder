import Foundation

public protocol CaptionFileTranscribing {
  func submitCaption(wav: Data) async throws -> String
  func captionResult(taskID: String) async throws -> String
}

/// The task has ended at the provider. A manual retry must submit a new task.
public struct FileTransTaskFailed: LocalizedError {
  public var errorDescription: String? { "云端未能完成本段转写。" }
}

extension AIService: CaptionFileTranscribing {
  public func submitCaption(wav: Data) async throws -> String {
    let api = try fileTransAPI()
    let model = LiveASRModel.fileTrans.rawValue
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    var policy = URLRequest(url: api.appendingPathComponent("uploads").appending(queryItems: [
      URLQueryItem(name: "action", value: "getPolicy"), URLQueryItem(name: "model", value: model),
    ]))
    policy.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    let policyData: FileUploadPolicy = try await fetch(policy, with: session)
    let object = try policyData.data.request(wav: wav)
    _ = try await response(object.request, with: session)
    try Task.checkCancellation()
    var submit = URLRequest(url: api.appendingPathComponent("services/audio/asr/transcription"))
    submit.httpMethod = "POST"
    submit.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    submit.setValue("application/json", forHTTPHeaderField: "Content-Type")
    submit.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
    submit.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
    submit.httpBody = try JSONSerialization.data(withJSONObject: [
      "model": model, "input": ["file_urls": ["oss://" + object.path]], "parameters": ["channel_id": [0]],
    ])
    let task: FileTransTask = try await fetch(submit, with: session)
    guard let id = task.output.task_id, validFileTaskID(id) else { throw WorkdayError.invalid("云端未返回转写任务编号。") }
    return id
  }

  public func captionResult(taskID: String) async throws -> String {
    guard validFileTaskID(taskID) else { throw FileTransTaskFailed() }
    let api = try fileTransAPI()
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    var poll = URLRequest(url: api.appendingPathComponent("tasks").appendingPathComponent(taskID))
    poll.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    var delay = 500
    while ContinuousClock.now < deadline {
      let task: FileTransTask = try await fetch(poll, with: session)
      switch task.output.task_status {
      case "SUCCEEDED":
        guard let result = task.output.results?.first, let address = result.transcription_url,
              let url = trustedFileURL(address) else { throw FileTransTaskFailed() }
        let file: FileTransResult = try await fetch(URLRequest(url: url), with: session)
        return file.transcripts.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      case "PENDING", "RUNNING":
        try await Task.sleep(for: .milliseconds(delay))
        delay = min(3000, delay * 2)
      case "FAILED", "CANCELED", "UNKNOWN": throw FileTransTaskFailed()
      default: throw WorkdayError.invalid("云端返回了未知的转写状态。")
      }
    }
    throw WorkdayError.invalid("分段转写仍在等待云端，可稍后再查。")
  }

  private func fileTransAPI() throws -> URL {
    guard !key.isEmpty,
          host == "dashscope.aliyuncs.com" || host.range(of: #"^[a-zA-Z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$"#,
                                                        options: .regularExpression) != nil,
          let base = URL(string: "https://" + host + "/api/v1") else { throw WorkdayError.invalid("百炼服务配置无效。") }
    return base
  }

  private func validFileTaskID(_ id: String) -> Bool {
    (1...128).contains(id.utf8.count) && id.range(of: #"^[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil
  }

  private func fetch<T: Decodable>(_ request: URLRequest, with session: URLSession) async throws -> T {
    try JSONDecoder().decode(T.self, from: try await response(request, with: session))
  }

  private func response(_ request: URLRequest, with session: URLSession) async throws -> Data {
    try Task.checkCancellation()
    var request = request
    request.timeoutInterval = 25
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw WorkdayError.invalid("FileTrans 请求失败（HTTP " + String((response as? HTTPURLResponse)?.statusCode ?? 0) + "）。")
    }
    guard data.count <= 4_000_000 else { throw WorkdayError.invalid("分段转写响应过大。") }
    return data
  }
}

private func trustedFileURL(_ address: String) -> URL? {
  guard let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
        url.host?.hasSuffix(".aliyuncs.com") == true else { return nil }
  return url
}

private struct FileUploadPolicy: Decodable {
  let data: Fields

  struct Fields: Decodable {
    let upload_host, upload_dir, oss_access_key_id, signature, policy, x_oss_object_acl, x_oss_forbid_overwrite: String

    func request(wav: Data) throws -> (request: URLRequest, path: String) {
      guard let url = trustedFileURL(upload_host) else { throw WorkdayError.invalid("云端上传地址无效。") }
      let boundary = UUID().uuidString
      let filename = UUID().uuidString + ".wav"
      let path = upload_dir + "/" + filename
      let fields = ["OSSAccessKeyId": oss_access_key_id, "Signature": signature, "policy": policy,
                    "x-oss-object-acl": x_oss_object_acl, "x-oss-forbid-overwrite": x_oss_forbid_overwrite,
                    "key": path, "success_action_status": "200"]
      var body = Data()
      for (key, value) in fields {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
      }
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
      body.append(wav)
      body.append(Data("\r\n--\(boundary)--\r\n".utf8))
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
      request.httpBody = body
      return (request, path)
    }
  }
}

private struct FileTransTask: Decodable {
  let output: Output
  struct Output: Decodable {
    let task_id, task_status: String?
    let results: [ResultFile]?
  }
  struct ResultFile: Decodable { let transcription_url: String? }
}

private struct FileTransResult: Decodable {
  let transcripts: [Transcript]
  struct Transcript: Decodable { let text: String }
}
