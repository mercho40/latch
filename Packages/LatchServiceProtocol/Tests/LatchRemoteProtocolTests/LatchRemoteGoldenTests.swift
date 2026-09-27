import Foundation
import LatchACP
import LatchRemoteProtocol
import LatchServiceProtocol
import XCTest

/// The wire format, frozen as sorted-key JSON. A change here is a protocol change.
final class LatchRemoteGoldenTests: XCTestCase {
    private let id = Sample.runtimeID

    func testClientFrames() throws {
        let cases: [(LatchRemoteClientFrame, String)] = [
            (.hello(LatchRemoteHello(
                token: Sample.token,
                client: LatchRemoteClientInfo(name: "Latch", version: "0.2.0", platform: "macOS 26.0")
            )), #"{"client":{"name":"Latch","platform":"macOS 26.0","version":"0.2.0"},"protocol":{"max":1,"min":1},"token":"latch_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","type":"hello"}"#),
            (.request(LatchRemoteRequest(id: Sample.frameID, command: .listRuntimes)), #"{"command":{"kind":"listRuntimes"},"id":"00000000-0000-0000-0000-00000000000C","type":"request"}"#),
            (.ping, #"{"type":"ping"}"#),
        ]
        for (frame, fixture) in cases {
            try assertGolden(frame, fixture)
        }
    }

    func testServerFrames() throws {
        let server = LatchRemoteServerInfo(version: "0.2.0", hostname: "vps", os: "Linux", arch: "aarch64", home: "/home/me")
        let cases: [(LatchRemoteServerFrame, String)] = [
            (.welcome(LatchRemoteWelcome(protocolVersion: 1, server: server)), #"{"heartbeatSeconds":15,"maxFrameBytes":8454144,"protocol":1,"server":{"arch":"aarch64","home":"/home/me","hostname":"vps","os":"Linux","version":"0.2.0"},"type":"welcome"}"#),
            (.rejected(LatchRemoteRejected(
                reason: .protocolMismatch, message: "Update Latch.", supported: LatchRemoteVersionRange(min: 1, max: 1)
            )), #"{"message":"Update Latch.","reason":"protocolMismatch","supported":{"max":1,"min":1},"type":"rejected"}"#),
            (.rejected(LatchRemoteRejected(reason: .unauthorized, message: "The token is not valid.")), #"{"message":"The token is not valid.","reason":"unauthorized","type":"rejected"}"#),
            (.reply(LatchRemoteReply(id: Sample.frameID, result: .success(.stopped))), #"{"id":"00000000-0000-0000-0000-00000000000C","result":{"ok":{"kind":"stopped"}},"type":"reply"}"#),
            (.reply(LatchRemoteReply(
                id: Sample.frameID, result: .failure(LatchRemoteError(code: .runtimeNotFound, message: "No such runtime."))
            )), #"{"error":{"code":"runtimeNotFound","message":"No such runtime."},"id":"00000000-0000-0000-0000-00000000000C","type":"reply"}"#),
            // The answer to a frame of an unknown type that carried an id.
            (.reply(LatchRemoteReply(
                id: Sample.frameID, result: .failure(LatchRemoteError(code: .unsupported, message: "Unknown frame type."))
            )), #"{"error":{"code":"unsupported","message":"Unknown frame type."},"id":"00000000-0000-0000-0000-00000000000C","type":"reply"}"#),
            (.invalidReply(id: Sample.frameID), #"{"id":"00000000-0000-0000-0000-00000000000C","type":"reply"}"#),
            (.event(LatchRemoteEventFrame(runtimeID: id, sequence: 3, event: .permissionClosed(requestID: Sample.requestID))), #"{"event":{"kind":"permissionClosed","requestID":"00000000-0000-0000-0000-00000000000B"},"runtimeID":"rt-1","sequence":3,"type":"event"}"#),
            (.event(LatchRemoteEventFrame(
                runtimeID: id, sequence: 4, event: .permissionClosed(requestID: Sample.requestID), gap: true
            )), #"{"event":{"kind":"permissionClosed","requestID":"00000000-0000-0000-0000-00000000000B"},"gap":true,"runtimeID":"rt-1","sequence":4,"type":"event"}"#),
            (.pong, #"{"type":"pong"}"#),
        ]
        for (frame, fixture) in cases {
            try assertGolden(frame, fixture)
        }
    }

    func testCommands() throws {
        let cases: [(LatchRemoteCommand, String)] = [
            (.launchAgent(runtimeID: id, agent: .preset("claudeCode"), workspace: "/home/me/project"), #"{"agent":{"preset":"claudeCode"},"kind":"launchAgent","runtimeID":"rt-1","workspace":"/home/me/project"}"#),
            (.launchAgent(runtimeID: id, agent: .custom("my-agent --acp"), workspace: "/srv/work"), #"{"agent":{"custom":"my-agent --acp"},"kind":"launchAgent","runtimeID":"rt-1","workspace":"/srv/work"}"#),
            (.newSession(runtimeID: id), #"{"kind":"newSession","runtimeID":"rt-1"}"#),
            (.loadSession(runtimeID: id, sessionID: "session-1"), #"{"kind":"loadSession","runtimeID":"rt-1","sessionID":"session-1"}"#),
            (.setConfigOption(runtimeID: id, configID: "effort", value: "high"), #"{"configID":"effort","kind":"setConfigOption","runtimeID":"rt-1","value":"high"}"#),
            (.setModel(runtimeID: id, modelID: "model-b"), #"{"kind":"setModel","modelID":"model-b","runtimeID":"rt-1"}"#),
            (.setMode(runtimeID: id, modeID: "ask"), #"{"kind":"setMode","modeID":"ask","runtimeID":"rt-1"}"#),
            (.prompt(runtimeID: id, turnID: Sample.turnID, blocks: [
                .text("What is this?"),
                .image(data: Data([1, 2, 3]), mimeType: "image/png"),
                .resourceLink(uri: "file:///home/me/project/a.txt", name: "a.txt", mimeType: nil),
            ]), #"{"blocks":[{"text":"What is this?","type":"text"},{"data":"AQID","mimeType":"image/png","type":"image"},{"name":"a.txt","type":"resource_link","uri":"file:///home/me/project/a.txt"}],"kind":"prompt","runtimeID":"rt-1","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.prompt(runtimeID: id, turnID: Sample.turnID, blocks: [
                .resourceLink(uri: "file:///srv/b.md", name: "b.md", mimeType: "text/markdown"),
            ]), #"{"blocks":[{"mimeType":"text/markdown","name":"b.md","type":"resource_link","uri":"file:///srv/b.md"}],"kind":"prompt","runtimeID":"rt-1","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.cancelPrompt(runtimeID: id), #"{"kind":"cancelPrompt","runtimeID":"rt-1"}"#),
            (.resolvePermission(runtimeID: id, requestID: Sample.requestID, outcome: .selected(optionID: "allow-once")), #"{"kind":"resolvePermission","outcome":{"optionId":"allow-once","outcome":"selected"},"requestID":"00000000-0000-0000-0000-00000000000B","runtimeID":"rt-1"}"#),
            (.resolvePermission(runtimeID: id, requestID: Sample.requestID, outcome: .cancelled), #"{"kind":"resolvePermission","outcome":{"outcome":"cancelled"},"requestID":"00000000-0000-0000-0000-00000000000B","runtimeID":"rt-1"}"#),
            (.attach(runtimeID: id, after: 0), #"{"after":0,"kind":"attach","runtimeID":"rt-1"}"#),
            (.detach(runtimeID: id), #"{"kind":"detach","runtimeID":"rt-1"}"#),
            (.stopRuntime(runtimeID: id), #"{"kind":"stopRuntime","runtimeID":"rt-1"}"#),
            (.listRuntimes, #"{"kind":"listRuntimes"}"#),
        ]
        for (command, fixture) in cases {
            try assertGolden(command, fixture)
        }
    }

    func testResponses() throws {
        let cases: [(LatchRemoteResponse, String)] = [
            (.launched(initialization: Sample.initialization), #"{"initialization":{"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}},"agentInfo":{"name":"mock-agent","version":"1.0.0"},"protocolVersion":1},"kind":"launched"}"#),
            (.sessionCreated(response: Sample.newSession), #"{"kind":"sessionCreated","response":{"localSequence":2,"modes":{"currentModeId":"ask"},"sessionId":"session-1"}}"#),
            (.sessionLoaded(response: Sample.loadSession), #"{"kind":"sessionLoaded","response":{"localSequence":9,"models":{"currentModelId":"model-b"}}}"#),
            (.configOptionSet(response: ACPSetSessionConfigOptionResponse(configOptions: Sample.configOptions, localSequence: 7)), #"{"kind":"configOptionSet","response":{"configOptions":[{"currentValue":"high","id":"effort"}],"localSequence":7}}"#),
            (.modelSet(sequence: 8), #"{"kind":"modelSet","sequence":8}"#),
            (.modeSet(sequence: 9), #"{"kind":"modeSet","sequence":9}"#),
            (.promptAccepted(turnID: Sample.turnID), #"{"kind":"promptAccepted","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.cancelRequested, #"{"kind":"cancelRequested"}"#),
            (.permissionResolved, #"{"kind":"permissionResolved"}"#),
            (.attached(record: Sample.record, backlogFrom: 5, truncated: false), #"{"backlogFrom":5,"kind":"attached","record":{"activeTurnID":"00000000-0000-0000-0000-00000000000A","agent":{"preset":"claudeCode"},"agentTitle":"Claude Code","configurationSets":[{"acpSequence":7,"configID":"effort","configOptions":[{"currentValue":"high","id":"effort"}],"route":"config","value":"high"}],"initialization":{"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}},"agentInfo":{"name":"mock-agent","version":"1.0.0"},"protocolVersion":1},"lastSequence":12,"lifecycle":"ready","pendingPermissions":[{"request":{"options":[{"kind":"allow_once","name":"Allow","optionId":"allow-once"}],"sessionId":"session-1","toolCall":{"title":"Read file","toolCallId":"call-1"}},"requestID":"00000000-0000-0000-0000-00000000000B"}],"runtimeID":"rt-1","session":{"kind":"new","response":{"localSequence":2,"modes":{"currentModeId":"ask"},"sessionId":"session-1"}},"sessionID":"session-1","state":[{"localSequence":6,"sessionId":"session-1","update":{"currentModeId":"code","sessionUpdate":"current_mode_update"}}],"turns":[{"state":"running","turnID":"00000000-0000-0000-0000-00000000000A"}],"workspace":"/home/me/project"},"truncated":false}"#),
            (.attached(record: Sample.exitedRecord, backlogFrom: 31, truncated: true), #"{"backlogFrom":31,"kind":"attached","record":{"agent":{"custom":"my-agent --acp"},"agentTitle":"my-agent","configurationSets":[],"exit":{"status":3,"stopped":false},"lastSequence":40,"lifecycle":"exited","loadedThrough":9,"pendingPermissions":[],"runtimeID":"rt-1","session":{"kind":"load","response":{"localSequence":9,"models":{"currentModelId":"model-b"}}},"sessionID":"session-2","state":[],"turns":[{"error":{"code":"runtimeExited","message":"The agent exited."},"state":"ended","turnID":"00000000-0000-0000-0000-00000000000A"}],"workspace":"/srv/work"},"truncated":true}"#),
            (.detached, #"{"kind":"detached"}"#),
            (.stopped, #"{"kind":"stopped"}"#),
            (.runtimes([LatchRemoteRuntimeSummary(
                runtimeID: id, agentTitle: "Claude Code", workspace: "/home/me/project", lifecycle: .ready,
                activeTurnID: Sample.turnID, pendingPermissionCount: 1, lastSequence: 12
            )]), #"{"kind":"runtimes","runtimes":[{"activeTurnID":"00000000-0000-0000-0000-00000000000A","agentTitle":"Claude Code","lastSequence":12,"lifecycle":"ready","pendingPermissionCount":1,"runtimeID":"rt-1","workspace":"/home/me/project"}]}"#),
        ]
        for (response, fixture) in cases {
            try assertGolden(response, fixture)
        }
    }

    func testEvents() throws {
        let cases: [(LatchRemoteEvent, String)] = [
            (.sessionUpdate(notification: Sample.notification), #"{"kind":"sessionUpdate","notification":{"localSequence":5,"sessionId":"session-1","update":{"content":{"text":"a/b","type":"text"},"sessionUpdate":"agent_message_chunk"}}}"#),
            (.permissionRequested(requestID: Sample.requestID, request: Sample.permission), #"{"kind":"permissionRequested","request":{"options":[{"kind":"allow_once","name":"Allow","optionId":"allow-once"}],"sessionId":"session-1","toolCall":{"title":"Read file","toolCallId":"call-1"}},"requestID":"00000000-0000-0000-0000-00000000000B"}"#),
            (.permissionClosed(requestID: Sample.requestID), #"{"kind":"permissionClosed","requestID":"00000000-0000-0000-0000-00000000000B"}"#),
            (.turnStarted(turnID: Sample.turnID, text: "Look at this", attachments: [
                LatchRemoteAttachmentSummary(kind: "image", mimeType: "image/png", byteCount: 2048),
                LatchRemoteAttachmentSummary(kind: "resourceLink", name: "a.txt", byteCount: 0),
            ]), #"{"attachments":[{"byteCount":2048,"kind":"image","mimeType":"image/png"},{"byteCount":0,"kind":"resourceLink","name":"a.txt"}],"kind":"turnStarted","text":"Look at this","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.turnEnded(turnID: Sample.turnID, stopReason: "end_turn", error: nil), #"{"kind":"turnEnded","stopReason":"end_turn","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.turnEnded(turnID: Sample.turnID, stopReason: nil, error: LatchRemoteError(
                code: .runtimeExited, message: "The agent exited."
            )), #"{"error":{"code":"runtimeExited","message":"The agent exited."},"kind":"turnEnded","turnID":"00000000-0000-0000-0000-00000000000A"}"#),
            (.configurationSet(Sample.configurationSet), #"{"acpSequence":7,"configID":"effort","configOptions":[{"currentValue":"high","id":"effort"}],"kind":"configurationSet","route":"config","value":"high"}"#),
            (.configurationSet(LatchRemoteConfigurationSet(route: .model, value: "model-b")), #"{"kind":"configurationSet","route":"model","value":"model-b"}"#),
            (.exited(LatchRemoteExit(status: 0, stopped: true)), #"{"kind":"exited","status":0,"stopped":true}"#),
            (.exited(LatchRemoteExit(status: nil, stopped: false)), #"{"kind":"exited","stopped":false}"#),
            (.omitted(originalKind: "sessionUpdate", byteCount: 9_000_000), #"{"byteCount":9000000,"kind":"omitted","originalKind":"sessionUpdate"}"#),
        ]
        for (event, fixture) in cases {
            try assertGolden(event, fixture)
        }
    }
}
