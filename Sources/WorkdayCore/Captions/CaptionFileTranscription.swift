import Foundation

public protocol CaptionFileTranscribing {
  func transcribeCaption(wav: Data) async throws -> String
}

extension AIService: CaptionFileTranscribing {}
