import Foundation

public enum ConversationBoundary {
  /// Revisit only adjacent proposals that touch an analysis-batch seam, using their actual sentences.
  public static func reconcile(
    _ proposals: [ConversationProposal], before: String, after: String,
    lines: [TranscriptLine], service: any InferenceServing
  ) async throws -> [ConversationProposal] {
    guard let left = proposals.firstIndex(where: { $0.lastID == before }),
      left + 1 < proposals.count,
      proposals[left + 1].firstID == after,
      let first = lines.firstIndex(where: { $0.id == proposals[left].firstID }),
      let last = lines.firstIndex(where: { $0.id == proposals[left + 1].lastID }), first <= last,
      let leftEnd = lines.first(where: { $0.id == before }),
      let rightStart = lines.first(where: { $0.id == after }),
      rightStart.start - leftEnd.end <= 30, lines[last].end - lines[first].start <= 1800
    else { return proposals }
    let evidence = Array(lines[first...last])
    guard evidence.reduce(0, { $0 + $1.text.utf8.count }) <= 48000 else { return proposals }
    let revised: [ConversationProposal]
    do {
      revised = try await service.organize(lines: evidence)
      try AIService.validate(revised, lines: evidence)
    } catch is InvalidConversationSelection {
      // A merge is optional. Both original excerpts have already passed validation.
      return proposals
    }
    // A seam pass cannot silently remove either original edge.
    guard revised.first?.firstID == proposals[left].firstID,
      revised.last?.lastID == proposals[left + 1].lastID
    else { return proposals }
    var result = proposals
    result.replaceSubrange(left...left + 1, with: revised)
    try AIService.validate(result, lines: lines)
    return result
  }
}
