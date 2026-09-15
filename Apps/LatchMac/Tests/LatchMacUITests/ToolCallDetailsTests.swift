import Foundation
import LatchACP
import XCTest
@testable import LatchMacUI

final class ToolCallDetailsTests: XCTestCase {
    private func event(_ fields: [String: ACPJSONValue] = [:]) -> ACPToolCallEvent {
        var update = fields
        update["sessionUpdate"] = .string("tool_call_update")
        update["toolCallId"] = .string("tool")
        let notification = ACPSessionNotification(sessionId: "session", update: .object(update))
        guard case let .toolCall(tool, _) = notification.event else { fatalError("Invalid test event") }
        return tool
    }

    private func text(_ value: String) -> ACPJSONValue {
        .object(["type": .string("content"), "content": .object([
            "type": .string("text"), "text": .string(value),
        ])])
    }

    private func diff(_ old: ACPJSONValue?, _ new: String, path: String = "/not/a/real/file") -> ACPJSONValue {
        var fields: [String: ACPJSONValue] = [
            "type": .string("diff"), "path": .string(path), "newText": .string(new),
        ]
        fields["oldText"] = old
        return .object(fields)
    }

    func testPartialUpdatesPreserveIndependentSnapshotsAndReplaceRatherThanAppend() {
        var details = ToolCallDetails()
        XCTAssertEqual(details.text, "")
        details.apply(event([
            "content": .array([text("first")]),
            "locations": .array([.object(["path": .string("/a"), "line": .integer(12)])]),
            "rawInput": .string("input one"), "rawOutput": .string("output one"),
        ]))
        let original = details.text
        details.apply(event(["status": .string("completed")]))
        XCTAssertEqual(details.text, original)
        details.apply(event(["content": .array([text("second")]), "rawOutput": .string("output two")]))
        XCTAssertFalse(details.text.contains("first"))
        XCTAssertFalse(details.text.contains("output one"))
        XCTAssertTrue(details.text.contains("Content:\nsecond"))
        XCTAssertTrue(details.text.contains("Locations:\n/a (line 12)"))
        XCTAssertTrue(details.text.contains("rawInput (text):\ninput one"))
        XCTAssertTrue(details.text.contains("rawOutput (text):\noutput two"))
        let updated = details.text
        details.apply(event(["content": .array([text("second")]), "rawOutput": .string("output two")]))
        XCTAssertEqual(details.text, updated)
    }

    func testEmptyCollectionsAndExplicitRawNullClearOnlyTheirSections() {
        var details = ToolCallDetails()
        details.apply(event([
            "content": .array([text("hello")]),
            "locations": .array([.object(["path": .string("/a")])]),
            "rawInput": .string("input"), "rawOutput": .string("output"),
        ]))
        details.apply(event(["content": .array([]), "rawInput": .null]))
        XCTAssertFalse(details.text.contains("Content:"))
        XCTAssertFalse(details.text.contains("rawInput"))
        XCTAssertTrue(details.text.contains("Locations:"))
        XCTAssertTrue(details.text.contains("rawOutput"))
        details.apply(event(["locations": .array([]), "rawOutput": .null]))
        XCTAssertEqual(details.text, "")
        details.apply(event(["rawInput": .array([]), "rawOutput": .object([:])]))
        XCTAssertTrue(details.text.contains("[]"))
        XCTAssertTrue(details.text.contains("{}"))
    }

    func testMalformedTopLevelCollectionsAreOmittedByACPProjection() {
        var details = ToolCallDetails()
        details.apply(event(["content": .array([text("keep")]), "locations": .array([.object(["path": .string("/keep")])])]))
        let original = details.text
        details.apply(event(["content": .string("invalid"), "locations": .null]))
        XCTAssertEqual(details.text, original)
        // ACPToolCallEvent cannot distinguish malformed/null collections from omission.
    }

    func testOnlyRecognizedNestedTextAndHarmlessMalformedNotices() {
        var details = ToolCallDetails()
        details.apply(event(["content": .array([
            text("recognized"), .null,
            .object(["type": .string("text"), "text": .string("hidden direct")]),
            .object(["type": .string("content"), "content": .object([
                "type": .string("resource"), "resource": .object(["text": .string("hidden recursive")]),
            ])]),
            .object(["type": .string("content"), "content": .object(["type": .string("text"), "text": .integer(3)])]),
            .object(["type": .string("diff"), "newText": .string("hidden invalid diff")]),
            .object(["type": .string("terminal")]),
        ])]))
        XCTAssertTrue(details.text.contains("recognized"))
        XCTAssertTrue(details.text.contains("Malformed content block"))
        XCTAssertTrue(details.text.contains("Unsupported"))
        XCTAssertTrue(details.text.contains("Malformed diff block"))
        XCTAssertTrue(details.text.contains("Malformed terminal reference"))
        XCTAssertFalse(details.text.contains("hidden"))
    }

    func testTerminalAndLocationsArePlainUnavailableReferences() {
        var details = ToolCallDetails()
        details.apply(event([
            "content": .array([.object(["type": .string("terminal"), "terminalId": .string("$(touch nope)")])]),
            "locations": .array([
                .object(["path": .string("file:///does/not/exist"), "line": .integer(0)]),
                .object(["path": .string("/null"), "line": .null]),
                .object(["path": .string("/bad"), "line": .integer(-1)]),
                .object(["path": .string("/large"), "line": .integer(Int64.max)]),
                .object(["path": .string("/fraction"), "line": .double(1.5)]), .bool(false),
            ]),
        ]))
        XCTAssertTrue(details.text.contains("Terminal reference: $(touch nope)"))
        XCTAssertTrue(details.text.contains("Terminal output unavailable; not executed"))
        XCTAssertTrue(details.text.contains("file:///does/not/exist (line 0)"))
        XCTAssertTrue(details.text.contains("/null"))
        XCTAssertTrue(details.text.contains("Malformed line number"))
        XCTAssertTrue(details.text.contains("Malformed location"))
        XCTAssertFalse(details.text.contains("]("))
    }

    func testRawTextAndStructuralPreviewsStaySeparateFromContent() {
        var details = ToolCallDetails()
        details.apply(event([
            "content": .array([text("actual content")]),
            "rawInput": .object(["nested": .object(["text": .string("not extracted")])]),
            "rawOutput": .array([.null, .bool(true), .integer(4), .double(1.5), .string("quoted\n\"text")]),
        ]))
        XCTAssertTrue(details.text.contains("Content:\nactual content"))
        XCTAssertTrue(details.text.contains("rawInput (structural JSON preview):"))
        XCTAssertTrue(details.text.contains("\"nested\": {\"text\": \"not extracted\"}"))
        XCTAssertTrue(details.text.contains("rawOutput (structural JSON preview):\n[null, true, 4, 1.5,"))
        XCTAssertTrue(details.text.contains("quoted\\n\\\"text"))
        details.apply(event(["rawOutput": .double(.infinity)]))
        XCTAssertTrue(details.text.contains("Unsupported non-finite number"))
    }

    func testUnicodeAndHugeBlobsRespectCombinedUTF8BoundAndRetainOnlyStrings() {
        let huge = String(repeating: "🧑🏽‍💻e\u{301}", count: 100_000)
        var details = ToolCallDetails()
        details.apply(event([
            "content": .array([text(huge)]),
            "locations": .array(Array(repeating: .object(["path": .string(huge)]), count: 100)),
            "rawInput": .string(huge), "rawOutput": .string(huge),
        ]))
        XCTAssertLessThanOrEqual(details.text.utf8.count, 16_006)
        XCTAssertTrue(details.text.contains("[truncated]"))
        XCTAssertFalse(details.text.contains("\u{FFFD}"))
        let stored = Mirror(reflecting: details).children.compactMap { $0.value as? String }
        XCTAssertEqual(stored.count, 4)
        XCTAssertLessThanOrEqual(stored.reduce(0) { $0 + $1.utf8.count }, 16_000)
        details.apply(event(["rawInput": .string("short"), "rawOutput": .string("short")]))
        XCTAssertTrue(details.text.contains("rawInput (text):\nshort"))
        XCTAssertTrue(details.text.contains("rawOutput (text):\nshort"))
    }

    func testHugeSingleGraphemeIsByteBounded() {
        let huge = "e" + String(repeating: "\u{301}", count: 100_000)
        var details = ToolCallDetails()
        details.apply(event(["rawOutput": .string(huge)]))
        XCTAssertLessThanOrEqual(details.text.utf8.count, 4_000)
        XCTAssertTrue(details.text.contains("truncated"))
        XCTAssertFalse(details.text.contains("\u{FFFD}"))
    }

    func testDeepWideJSONAndHugeKeysAreBoundedBeforeSerialization() {
        var deep: ACPJSONValue = .string("unreachable leaf")
        for _ in 0..<200 { deep = .object(["child": deep]) }
        var details = ToolCallDetails()
        details.apply(event(["rawInput": deep]))
        XCTAssertTrue(details.text.contains("truncated: JSON depth/items"))
        XCTAssertFalse(details.text.contains("unreachable leaf"))
        let huge = String(repeating: "x", count: 1_000_000)
        details.apply(event(["rawOutput": .array(Array(repeating: .object([huge: .string(huge)]), count: 10_000))]))
        XCTAssertLessThanOrEqual(details.text.utf8.count, 6_002)
        XCTAssertTrue(details.text.contains("truncated"))
        details.apply(event(["rawInput": .array(Array(repeating: .integer(1), count: 100))]))
        XCTAssertTrue(details.text.contains("truncated: JSON items"))
    }

    func testBlocksAndLinesHaveExplicitTruncation() {
        var details = ToolCallDetails()
        details.apply(event(["content": .array(Array(repeating: text("x"), count: 1_000))]))
        XCTAssertTrue(details.text.contains("truncated: additional items omitted"))
        details.apply(event(["content": .array([text(String(repeating: "x\n", count: 10_000))])]))
        XCTAssertTrue(details.text.contains("truncated"))
        XCTAssertLessThanOrEqual(details.text.filter { $0 == "\n" }.count, 121)
    }

    func testChangedDiffWithPrefixSuffixContext() {
        let old = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "line 6\n", with: "replacement\n")
        let result = ToolCallDetails.lineDiff(oldText: .string(old), newText: new)
        XCTAssertTrue(result.contains("@@ -3,7 +3,7 @@"))
        XCTAssertTrue(result.contains(" line 5\n-line 6\n+replacement\n line 7\n"))
        XCTAssertTrue(result.contains("[2 unchanged lines omitted]"))
        XCTAssertTrue(result.contains("[3 unchanged lines omitted]"))
        XCTAssertFalse(result.contains("+line 7"))
        var details = ToolCallDetails()
        details.apply(event(["content": .array([diff(.string(old), new)])]))
        XCTAssertTrue(details.text.contains("Diff: /not/a/real/file"))
        XCTAssertTrue(details.text.contains("-line 6\n+replacement"))
    }

    func testNewFileEmptyFileAndDeletion() {
        let new = ToolCallDetails.lineDiff(oldText: .null, newText: "hello\n")
        XCTAssertTrue(new.contains("New file: oldText is null"))
        XCTAssertTrue(new.contains("@@ -0,0 +1,1 @@\n+hello\n"))
        XCTAssertFalse(new.contains("\n+\n"))
        XCTAssertTrue(ToolCallDetails.lineDiff(oldText: .null, newText: "").contains("New file"))
        XCTAssertTrue(ToolCallDetails.lineDiff(oldText: .string(""), newText: "").contains("No text changes"))
        let deleted = ToolCallDetails.lineDiff(oldText: .string("gone\n"), newText: "")
        XCTAssertTrue(deleted.contains("@@ -1,1 +0,0 @@\n-gone\n"))
        XCTAssertFalse(deleted.contains("\n+"))
    }

    func testUnknownMalformedAndTruncatedBaselinesNeverFabricateAdditions() {
        for old: ACPJSONValue? in [nil, .integer(3), .object([:])] {
            let result = ToolCallDetails.lineDiff(oldText: old, newText: "not necessarily new\n")
            XCTAssertTrue(result.contains("additions unknown"))
            XCTAssertFalse(result.contains("@@"))
            XCTAssertFalse(result.contains("\n+not necessarily new"))
        }
        let huge = String(repeating: "same\n", count: 10_000)
        for (old, new) in [(huge, huge), ("short\n", huge), (huge, "short\n")] {
            let result = ToolCallDetails.lineDiff(oldText: .string(old), newText: new)
            XCTAssertTrue(result.contains("truncated: diff input; comparison unavailable"))
            XCTAssertFalse(result.contains("@@"))
            XCTAssertFalse(result.contains("No text changes"))
            XCTAssertLessThanOrEqual(result.utf8.count, 7_000)
        }
    }

    func testDiffUsesByteExactUnicodeAndBoundsHugeSingleLineInputs() {
        let result = ToolCallDetails.lineDiff(oldText: .string("é\n"), newText: "e\u{301}\n")
        XCTAssertTrue(result.contains("@@ -1,1 +1,1 @@"))
        XCTAssertFalse(result.contains("No text changes"))
        let huge = String(repeating: "🦊", count: 100_000)
        let bounded = ToolCallDetails.lineDiff(oldText: .string(huge), newText: "small")
        XCTAssertTrue(bounded.contains("truncated: diff input"))
        XCTAssertLessThanOrEqual(bounded.utf8.count, 7_000)
        XCTAssertFalse(bounded.contains("\u{FFFD}"))
        XCTAssertFalse(bounded.contains("\n+small"))
    }

    func testLocationAndInputSnapshotsReplaceAndMalformedBlocksReplaceOldContent() {
        var details = ToolCallDetails()
        details.apply(event([
            "locations": .array([.object(["path": .string("/old")])]),
            "rawInput": .string("old input"), "content": .array([text("old content")]),
        ]))
        details.apply(event([
            "locations": .array([.object(["path": .string("/new")])]),
            "rawInput": .string("new input"), "content": .array([.null]),
        ]))
        XCTAssertFalse(details.text.contains("old"))
        XCTAssertTrue(details.text.contains("Locations:\n/new"))
        XCTAssertTrue(details.text.contains("rawInput (text):\nnew input"))
        XCTAssertTrue(details.text.contains("Malformed content block"))
    }

    func testEmptyAndExoticNewlinesAreNotFabricatedOrLost() {
        let newline = ToolCallDetails.lineDiff(oldText: .string(""), newText: "\n")
        XCTAssertTrue(newline.contains("@@ -0,0 +1,1 @@\n+\n"))
        let finalNewline = ToolCallDetails.lineDiff(oldText: .string("a"), newText: "a\n")
        XCTAssertTrue(finalNewline.contains("-a\n\\ No newline at end of file\n+a\n"))
        for ending in ["\r\n", "\r", "\u{85}", "\u{2028}", "\u{2029}"] {
            let old = "a" + ending
            XCTAssertTrue(ToolCallDetails.lineDiff(oldText: .string(old), newText: old).contains("No text changes"))
            let result = ToolCallDetails.lineDiff(oldText: .string(old), newText: "a\n")
            XCTAssertTrue(result.contains("-a\n\\ Line ending: U+"))
            XCTAssertTrue(result.contains("+a\n"))
        }
        let blank = ToolCallDetails.lineDiff(oldText: .string("\n\n"), newText: "\n")
        XCTAssertTrue(blank.contains("\n-\n"))
        XCTAssertFalse(blank.contains("\n+\n"))
    }
}
