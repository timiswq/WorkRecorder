import XCTest
@testable import QS668Core

final class TranscriptionTests: XCTestCase {
    func testEmptyFinalRetractsTextWithoutBlankLinesOrLatePartialResurrection() {
        var transcript = ASRTranscript()
        transcript.apply(.sentence(id: 1, text: "保留正文", isFinal: true), segment: 0)
        transcript.apply(.sentence(id: 2, text: "临时正文", isFinal: false), segment: 0)
        transcript.apply(.sentence(id: 2, text: " \n", isFinal: true), segment: 0)
        transcript.apply(.sentence(id: 2, text: "迟到的临时正文", isFinal: false), segment: 0)
        transcript.apply(.sentence(id: 3, text: "", isFinal: true), segment: 0)
        transcript.apply(.sentence(id: 3, text: "另一迟到结果", isFinal: false), segment: 0)
        XCTAssertEqual(transcript.text, "保留正文")
    }

    func testWordsKeepPunctuationSegmentOffsetAndPersistence() throws {
        let event = try ASREvent.parse(Data(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"第一句。第二句。","sentence_end":true,"begin_time":100,"end_time":2000,"words":[{"text":"第一句","punctuation":"。","begin_time":100,"end_time":900},{"text":"第二句。","punctuation":"。","begin_time":1100,"end_time":2000},{"text":"","begin_time":0,"end_time":0},{"text":"无效","begin_time":true,"end_time":100}]}}}}"#.utf8))
        var transcript = ASRTranscript(); transcript.apply(event, segment: 1, offsetMs: 5000)
        let sentence = transcript.sentences[0]
        XCTAssertEqual(sentence.words, [ASRWord(text: "第一句。", startMs: 5100, endMs: 5900), ASRWord(text: "第二句。", startMs: 6100, endMs: 7000)])
        XCTAssertEqual(try JSONDecoder().decode(ASRSentence.self, from: JSONEncoder().encode(sentence)), sentence)
        var unknownOffset = ASRTranscript(); unknownOffset.apply(event, segment: 2, offsetMs: nil)
        XCTAssertNil(unknownOffset.sentences[0].words)
    }

    func testSentenceAudioTimesAreParsedAndPersisted() throws {
        let event = try ASREvent.parse(Data(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"时间测试。","sentence_end":true,"begin_time":760,"end_time":3800}}}}"#.utf8))
        var transcript = ASRTranscript(); transcript.apply(event, segment: 0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(transcript.sentences[0])) as! [String: Any]
        XCTAssertEqual(json["startMs"] as? Double, 760)
        XCTAssertEqual(json["endMs"] as? Double, 3800)
    }

    func testInvalidTimesAndLegacySentenceDoNotInventAudioOffsets() throws {
        for fields in [#""begin_time":-1,"end_time":20"#, #""begin_time":200,"end_time":100"#, #""begin_time":true,"end_time":100"#, #""begin_time":"0","end_time":100"#] {
            let event = try ASREvent.parse(Data("{\"header\":{\"event\":\"result-generated\"},\"payload\":{\"output\":{\"sentence\":{\"sentence_id\":1,\"text\":\"测试\",\"sentence_end\":true,\(fields)}}}}".utf8))
            var transcript = ASRTranscript(); transcript.apply(event, segment: 0)
            XCTAssertNil(transcript.sentences[0].startMs); XCTAssertNil(transcript.sentences[0].endMs)
        }
        let legacy = try JSONDecoder().decode(ASRSentence.self, from: Data(#"{"segment":0,"sentence":1,"text":"旧稿","isFinal":true}"#.utf8))
        XCTAssertNil(legacy.startMs); XCTAssertNil(legacy.endMs)
    }
    func testIntermediateTextReplacesSameSentenceAndFinalCannotRegress() throws {
        var transcript = ASRTranscript()
        for (text, final) in [("今天", false), ("今天天气", false), ("今天天气很好。", true), ("今天", false)] {
            let event = try ASREvent.parse(Data("""
            {"header":{"event":"result-generated","task_id":"a"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"\(text)","sentence_end":\(final)}}}}
            """.utf8))
            transcript.apply(event, segment: 0)
        }
        XCTAssertEqual(transcript.sentences.map(\.text), ["今天天气很好。"])
        XCTAssertTrue(transcript.sentences[0].isFinal)
    }

    func testSegmentIDsSeparateResumeAndLateFinalResultsStayInOrder() throws {
        var transcript = ASRTranscript()
        transcript.apply(.sentence(id: 1, text: "后半段", isFinal: false), segment: 1)
        transcript.apply(.sentence(id: 1, text: "前半段。", isFinal: true), segment: 0)
        transcript.apply(.sentence(id: 1, text: "后半段。", isFinal: true), segment: 1)
        XCTAssertEqual(transcript.sentences.map(\.text), ["前半段。", "后半段。"])
        let heartbeat = try ASREvent.parse(Data(#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"heartbeat":true,"sentence_id":0}}}}"#.utf8))
        transcript.apply(heartbeat, segment: 1)
        XCTAssertEqual(transcript.sentences.count, 2)
    }

    func testStreamingOpusKeepsSplitPacketsAndWritesContinuousGranules() throws {
        let raw = Data(Array(repeating: [UInt8(0x48)] + Array(1...39), count: 13).flatMap { $0 })
        var stream = OggOpusStream()
        var pages = try stream.append(raw.prefix(17))
        pages += try stream.append(raw.dropFirst(17))
        pages += try stream.finish()
        XCTAssertEqual(pages.count, 4) // Head, tags, 10 packets, final 3 packets.
        let firstAudio = Array(pages[2]), last = Array(pages[3])
        XCTAssertEqual(firstAudio[26], 10)
        XCTAssertEqual(Wire.le32(firstAudio[6..<10]), 9600)
        XCTAssertEqual(last[5], 4)
        XCTAssertEqual(last[26], 3)
        XCTAssertEqual(Wire.le32(last[6..<10]), 12480)
        XCTAssertEqual(Data(firstAudio.dropFirst(37)) + Data(last.dropFirst(30)), raw)
    }

    func testStreamingOpusRejectsUnknownFormatAndIncompleteTail() throws {
        var bad = OggOpusStream()
        XCTAssertThrowsError(try bad.append(Data(repeating: 0, count: 440)))
        var tail = OggOpusStream()
        _ = try tail.append(Data([0x48]))
        XCTAssertThrowsError(try tail.finish())
    }
}
