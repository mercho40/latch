import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

/// A newer peer must never break an older one: unknown types, kinds, codes and keys decode.
final class LatchRemoteToleranceTests: XCTestCase {
    private let id = "00000000-0000-0000-0000-00000000000C"

    func testUnknownClientFrameTypeKeepsItsID() throws {
        XCTAssertEqual(
            try decoded(LatchRemoteClientFrame.self, #"{"type":"subscribe","id":"\#(id)","topic":"x"}"#),
            .unknown(type: "subscribe", id: Sample.frameID)
        )
        XCTAssertEqual(try decoded(LatchRemoteClientFrame.self, #"{"type":"subscribe"}"#), .unknown(type: "subscribe", id: nil))
        XCTAssertEqual(try decoded(LatchRemoteClientFrame.self, #"{"type":"subscribe","id":7}"#), .unknown(type: "subscribe", id: nil))
    }

    func testUnknownServerFrameType() throws {
        XCTAssertEqual(try decoded(LatchRemoteServerFrame.self, #"{"type":"notice","text":"hi"}"#), .unknown(type: "notice"))
    }

    func testUnknownCommandKindStillDecodesTheRequest() throws {
        XCTAssertEqual(
            try decoded(LatchRemoteClientFrame.self, #"{"type":"request","id":"\#(id)","command":{"kind":"teleport","to":"mars"}}"#),
            .request(LatchRemoteRequest(id: Sample.frameID, command: .unknown(kind: "teleport")))
        )
    }

    func testMalformedCommandIsAnInvalidRequest() throws {
        let bodies = [
            #"{"kind":"prompt","runtimeID":"rt-1"}"#,
            #"{"kind":"stopRuntime","runtimeID":"has space"}"#,
            #"{"kind":"stopRuntime","runtimeID":""}"#,
            #"{"kind":"launchAgent","runtimeID":"rt-1","agent":{"preset":"a","custom":"b"},"workspace":"/"}"#,
            #"{"kind":"launchAgent","runtimeID":"rt-1","agent":{},"workspace":"/"}"#,
            #"{"kind":"launchAgent","runtimeID":"rt-1","agent":{"registry":"x"},"workspace":"/"}"#,
            #"{"kind":"prompt","runtimeID":"rt-1","turnID":"\#(id)","blocks":[{"type":"audio","data":"AQID"}]}"#,
            #"{"kind":"prompt","runtimeID":"rt-1","turnID":"\#(id)","blocks":[{"type":"image","data":"%%%","mimeType":"image/png"}]}"#,
            #"{"kind":"prompt","runtimeID":"rt-1","turnID":"\#(id)","blocks":[{"text":{"_0":"synthesized"}}]}"#,
            #"{"runtimeID":"rt-1"}"#,
            #""stopRuntime""#,
        ]
        for body in bodies {
            XCTAssertEqual(
                try decoded(LatchRemoteClientFrame.self, #"{"type":"request","id":"\#(id)","command":\#(body)}"#),
                .invalidRequest(id: Sample.frameID),
                body
            )
        }
        XCTAssertEqual(try decoded(LatchRemoteClientFrame.self, #"{"type":"request","id":"\#(id)"}"#), .invalidRequest(id: Sample.frameID))
    }

    func testFramesThatAreNotObjectsWithATypeAreFatal() {
        for line in ["[]", "42", #""ping""#, "{}", #"{"type":1}"#, "{"] {
            XCTAssertThrowsError(try decoded(LatchRemoteClientFrame.self, line), line)
            XCTAssertThrowsError(try decoded(LatchRemoteServerFrame.self, line), line)
        }
        // Without an ID there is nothing to answer.
        XCTAssertThrowsError(try decoded(LatchRemoteClientFrame.self, #"{"type":"request","id":"nope"}"#))
    }

    func testUnknownEventKindStillCarriesItsSequence() throws {
        let frame = try decoded(
            LatchRemoteServerFrame.self,
            #"{"type":"event","runtimeID":"rt-1","sequence":9,"event":{"kind":"usageReport","tokens":12}}"#
        )
        XCTAssertEqual(frame, .event(LatchRemoteEventFrame(runtimeID: Sample.runtimeID, sequence: 9, event: .unknown(kind: "usageReport"))))
    }

    func testKnownEventKindWithAnUndecodableBodyBecomesUnknown() throws {
        let bodies = [
            #"{"kind":"turnEnded","turnID":"not-a-uuid"}"#,
            #"{"kind":"sessionUpdate","notification":{"update":{}}}"#,
            #"{"kind":"exited","status":"zero","stopped":true}"#,
            #"{"kind":"configurationSet","route":"model"}"#,
            #"{"kind":"omitted"}"#,
        ]
        for body in bodies {
            let event = try decoded(LatchRemoteEvent.self, body)
            let kind = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])["kind"] as? String
            XCTAssertEqual(event, .unknown(kind: try XCTUnwrap(kind)), body)
        }
        XCTAssertThrowsError(try decoded(LatchRemoteEvent.self, #"{"requestID":"\#(id)"}"#))
    }

    func testEventFrameWithoutAKindStillCarriesItsSequence() throws {
        for event in [#"{"requestID":"\#(id)"}"#, "[]", "7", "null"] {
            XCTAssertEqual(
                try decoded(LatchRemoteServerFrame.self, #"{"type":"event","runtimeID":"rt-1","sequence":9,"event":\#(event)}"#),
                .event(LatchRemoteEventFrame(runtimeID: Sample.runtimeID, sequence: 9, event: .unknown(kind: ""))),
                event
            )
        }
    }

    func testEventFrameWithAnInvalidRuntimeIDIsFatal() {
        XCTAssertThrowsError(try decoded(
            LatchRemoteServerFrame.self,
            #"{"type":"event","runtimeID":"a\"b","sequence":1,"event":{"kind":"x"}}"#
        ))
    }

    func testUnknownFailureCodeDecodes() throws {
        let frame = try decoded(
            LatchRemoteServerFrame.self,
            #"{"type":"reply","id":"\#(id)","error":{"code":"quotaExceeded","message":"Slow down."}}"#
        )
        let code = LatchRemoteFailureCode(rawValue: "quotaExceeded")
        XCTAssertEqual(frame, .reply(LatchRemoteReply(id: Sample.frameID, result: .failure(LatchRemoteError(code: code, message: "Slow down.")))))
        XCTAssertNotEqual(code, .commandFailed)
    }

    func testUnknownResponseKindDecodes() throws {
        XCTAssertEqual(
            try decoded(LatchRemoteServerFrame.self, #"{"type":"reply","id":"\#(id)","result":{"ok":{"kind":"teleported","where":"mars"}}}"#),
            .reply(LatchRemoteReply(id: Sample.frameID, result: .success(.unknown(kind: "teleported"))))
        )
    }

    func testUndecodableReplyKeepsItsID() throws {
        let attached = try encodedString(LatchRemoteResponse.attached(record: Sample.record, backlogFrom: 1, truncated: false))
        let bodies = [
            "",
            #","result":{"ok":{"kind":"launched"}}"#,
            #","result":{"ok":{"kind":"promptAccepted","turnID":"nope"}}"#,
            #","result":{"partial":{}}"#,
            #","result":{"ok":\#(attached.replacingOccurrences(of: #""runtimeID":"rt-1""#, with: #""runtimeID":"a b""#))}"#,
            #","error":{"code":"busy"}"#,
            #","error":"busy""#,
        ]
        for body in bodies {
            XCTAssertEqual(
                try decoded(LatchRemoteServerFrame.self, #"{"type":"reply","id":"\#(id)"\#(body)}"#),
                .invalidReply(id: Sample.frameID),
                body
            )
        }
        // Without an ID there is no request to fail.
        XCTAssertThrowsError(try decoded(LatchRemoteServerFrame.self, #"{"type":"reply","result":{"ok":{"kind":"stopped"}}}"#))
    }

    func testRecordFromANewerServerDecodes() throws {
        var json = try encodedString(Sample.record)
        json = json.replacingOccurrences(of: #""agent":{"preset":"claudeCode"}"#, with: #""agent":{"registry":"x"}"#)
        json = json.replacingOccurrences(of: #""session":{"kind":"new""#, with: #""session":{"kind":"fork""#)
        let record = try decoded(LatchRemoteRuntimeRecord.self, json)
        XCTAssertEqual(record.agent, .unknown)
        XCTAssertEqual(record.session, .unknown(kind: "fork"))
        XCTAssertEqual(record.sessionID, "session-1")
    }

    func testHandshakeFramesIgnoreUnknownKeysAndValues() throws {
        let hello = try LatchRemoteHello.decode(line: Data(#"""
        {"type":"hello","protocol":{"min":1,"max":3,"preferred":2},"token":"t","client":{"name":"Latch","version":"9","platform":"iOS","device":"iPad"},"resume":true}
        """#.utf8))
        XCTAssertEqual(hello.protocolRange, LatchRemoteVersionRange(min: 1, max: 3))
        XCTAssertEqual(hello.client.platform, "iOS")

        let welcome = try decoded(LatchRemoteServerFrame.self, #"""
        {"type":"welcome","protocol":2,"server":{"version":"9","hostname":"h","os":"Linux","arch":"x86_64","home":"/root","uptime":5},"heartbeatSeconds":20,"maxFrameBytes":1024,"features":["x"]}
        """#)
        XCTAssertEqual(welcome, .welcome(LatchRemoteWelcome(
            protocolVersion: 2,
            server: LatchRemoteServerInfo(version: "9", hostname: "h", os: "Linux", arch: "x86_64", home: "/root"),
            heartbeatSeconds: 20,
            maxFrameBytes: 1024
        )))

        let rejected = try decoded(LatchRemoteRejected.self, #"{"type":"rejected","reason":"maintenance","message":"Later.","retryAfter":60}"#)
        XCTAssertEqual(rejected, LatchRemoteRejected(reason: LatchRemoteRejectReason(rawValue: "maintenance"), message: "Later."))
    }

    func testHelloDecoderAcceptsOnlyAHello() {
        let lines = [
            #"{"type":"request","id":"\#(id)","command":{"kind":"listRuntimes"}}"#,
            #"{"type":"ping"}"#,
            #"{"protocol":{"min":1,"max":1},"token":"t","client":{"name":"a","version":"b","platform":"c"}}"#,
            #"{"type":"hello","protocol":{"min":1,"max":1},"client":{"name":"a","version":"b","platform":"c"}}"#,
        ]
        for line in lines {
            XCTAssertThrowsError(try LatchRemoteHello.decode(line: Data(line.utf8)), line)
        }
    }

    func testHelloDescriptionNeverShowsTheToken() {
        let hello = LatchRemoteHello(token: Sample.token, client: LatchRemoteClientInfo(name: "Latch", version: "1", platform: "macOS"))
        XCTAssertFalse(String(describing: hello).contains(Sample.token))
        XCTAssertFalse(String(reflecting: hello).contains(Sample.token))
        XCTAssertFalse("\(hello)".contains("AAECAw"))
        var dumped = ""
        dump(hello, to: &dumped)
        XCTAssertFalse(dumped.contains("AAECAw"), dumped)
        XCTAssertTrue(dumped.contains("Latch"), dumped)
    }

    func testUnknownOpenStringsDecode() throws {
        let summary = try decoded(
            LatchRemoteRuntimeSummary.self,
            #"{"runtimeID":"rt-1","agentTitle":"A","workspace":"/w","lifecycle":"paused","pendingPermissionCount":0,"lastSequence":0}"#
        )
        XCTAssertEqual(summary.lifecycle, LatchRemoteLifecycle(rawValue: "paused"))
        let set = try decoded(LatchRemoteConfigurationSet.self, #"{"route":"effort","value":"high"}"#)
        XCTAssertEqual(set.route.rawValue, "effort")
    }

    func testSummaryTitleAndAgentAreOptional() throws {
        // As an older server sends it.
        let old = try decoded(
            LatchRemoteRuntimeSummary.self,
            #"{"runtimeID":"rt-1","agentTitle":"A","workspace":"/w","lifecycle":"ready","pendingPermissionCount":0,"lastSequence":3}"#
        )
        XCTAssertNil(old.title)
        XCTAssertNil(old.agent)
        XCTAssertFalse(try encodedString(old).contains("title"))
        XCTAssertFalse(try encodedString(old).contains(#""agent""#))

        let summary = LatchRemoteRuntimeSummary(
            runtimeID: Sample.runtimeID, agentTitle: "A", workspace: "/w", lifecycle: .ready,
            title: "Fix the build", agent: .custom("my-agent --acp")
        )
        XCTAssertEqual(try decoded(LatchRemoteRuntimeSummary.self, try encodedString(summary)), summary)
        // An agent form from a newer server still names the rest.
        let newer = try decoded(
            LatchRemoteRuntimeSummary.self,
            #"{"runtimeID":"rt-1","agentTitle":"A","workspace":"/w","lifecycle":"ready","pendingPermissionCount":0,"lastSequence":3,"title":"T","agent":{"registry":"x"}}"#
        )
        XCTAssertEqual(newer.agent, .unknown)
        XCTAssertEqual(newer.title, "T")
    }

    func testEncodingAnInvalidRuntimeIDFails() {
        let command = LatchRemoteCommand.stopRuntime(runtimeID: AgentRuntimeID("not/valid"))
        XCTAssertThrowsError(try LatchRemoteCoding.encodeLine(command))
    }
}
