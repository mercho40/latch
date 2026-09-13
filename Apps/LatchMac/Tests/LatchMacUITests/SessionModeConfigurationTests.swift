import Foundation
import LatchACP
import XCTest
@testable import LatchMacUI

final class SessionModeConfigurationTests: XCTestCase {
    private func json(_ text: String) throws -> ACPJSONValue {
        try JSONDecoder().decode(ACPJSONValue.self, from: Data(text.utf8))
    }

    private func select(
        id: String = "mode", category: ACPJSONValue? = nil,
        current: String = "a", options: [ACPJSONValue]? = nil, type: String = "select"
    ) -> ACPJSONValue {
        var object: [String: ACPJSONValue] = [
            "id": .string(id), "name": .string("Selector"), "type": .string(type),
            "currentValue": .string(current), "description": .string("Selector help"),
            "options": .array(options ?? [choice("a")])
        ]
        object["category"] = category
        return .object(object)
    }

    private func choice(_ value: String, name: String = "Alpha") -> ACPJSONValue {
        .object(["value": .string(value), "name": .string(name), "description": .string("Choice help")])
    }

    private func legacy() throws -> ACPJSONValue {
        try json(#"{"currentModeId":"old","availableModes":[{"id":"old","name":"Old","description":"Legacy help"}]}"#)
    }

    func testModernCategoriesUseActualConfigIDsAndPreferModernMode() throws {
        let configuration = SessionConfiguration(configOptions: [
            select(id: "vendor-mode", category: .string("mode")),
            select(id: "vendor-thinking", category: .string("thought_level"), current: "high",
                   options: [choice("high", name: "High")])
        ], modes: try legacy())
        XCTAssertEqual(configuration[.permissionMode]?.route, .config("vendor-mode"))
        XCTAssertEqual(configuration.permissionMode?.description, "Selector help")
        XCTAssertEqual(configuration.permissionMode?.choices, [
            .init(value: "a", name: "Alpha", description: "Choice help", group: nil)
        ])
        XCTAssertEqual(configuration[.effort]?.route, .config("vendor-thinking"))
        XCTAssertEqual(configuration.effort?.currentValue, "high")
    }

    func testCategoryIsAuthoritativeAndAbsentCategorySupportsKnownIDs() {
        for id in ["effort", "reasoning_effort", "thought_level"] {
            XCTAssertEqual(SessionConfiguration(configOptions: [select(id: id)]).effort?.route, .config(id))
        }
        XCTAssertNotNil(SessionConfiguration(configOptions: [select(category: .null)]).permissionMode)
        for category: ACPJSONValue in [.string("model"), .string("unknown"), .integer(3)] {
            XCTAssertNil(SessionConfiguration(configOptions: [select(category: category)]).permissionMode)
        }
        let overridden = SessionConfiguration(configOptions: [select(id: "mode", category: .string("thought_level"))])
        XCTAssertNil(overridden.permissionMode)
        XCTAssertEqual(overridden.effort?.route, .config("mode"))
    }

    func testOnlyCanonicalModeIDIsRecognizedWithoutCategory() {
        for id in ["permission", "permission_mode", "session_mode", "approval_policy", "sandbox"] {
            XCTAssertNil(SessionConfiguration(configOptions: [select(id: id)]).permissionMode)
            XCTAssertEqual(SessionConfiguration(configOptions: [
                select(id: id, category: .string("mode"))
            ]).permissionMode?.route, .config(id))
        }
        XCTAssertEqual(SessionConfiguration(configOptions: [select(id: "mode")]).permissionMode?.route, .config("mode"))
    }

    func testGroupedOptionsUseDisplayHeadersAndPreserveOrder() throws {
        let groups = try json(#"[{"group":"provider-id","name":"Provider","options":[{"value":"a","name":"Alpha","description":"Help"},null,{"value":"b","name":"Beta"}]},{"group":"other-id","name":"Other","options":[{"value":"c","name":"Gamma"}]}]"#)
        guard case let .array(options) = groups else { return XCTFail("Expected array") }
        let picker = try XCTUnwrap(SessionConfiguration(configOptions: [select(options: options)]).permissionMode)
        XCTAssertEqual(picker.choices, [
            .init(value: "a", name: "Alpha", description: "Help", group: "Provider"),
            .init(value: "b", name: "Beta", description: nil, group: "Provider"),
            .init(value: "c", name: "Gamma", description: nil, group: "Other")
        ])
    }

    func testUnavailableCurrentValueAndEmptyOptionsAreNotInvented() {
        let picker = SessionConfiguration(configOptions: [select(current: "missing")]).permissionMode
        XCTAssertEqual(picker?.currentValue, "missing")
        XCTAssertEqual(picker?.choices.map(\.value), ["a"])
        let empty = SessionConfiguration(configOptions: [select(current: "missing", options: [])]).permissionMode
        XCTAssertEqual(empty?.currentValue, "missing")
        XCTAssertEqual(empty?.choices, [])
    }

    func testLegacyFallbackAndCurrentModeUpdate() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], modes: try legacy())
        XCTAssertEqual(configuration.permissionMode?.route, .legacyMode)
        XCTAssertEqual(configuration.permissionMode?.choices, [
            .init(value: "old", name: "Old", description: "Legacy help", group: nil)
        ])
        XCTAssertNotNil(configuration.effort)
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"current_mode_update","currentModeId":"unlisted"}"#)))
        XCTAssertEqual(configuration.permissionMode?.currentValue, "unlisted")
        XCTAssertEqual(configuration.permissionMode?.choices.map(\.value), ["old"])
    }

    func testFullReplacementRemovesPickersWithoutResurrectingLegacy() throws {
        var configuration = SessionConfiguration(configOptions: [select(), select(id: "effort")], modes: try legacy())
        configuration.apply(configOptions: [select(id: "effort", current: "new")])
        XCTAssertNil(configuration.permissionMode)
        XCTAssertEqual(configuration.effort?.currentValue, "new")
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"config_option_update","configOptions":[]}"#)))
        XCTAssertEqual(configuration, SessionConfiguration())
        XCTAssertFalse(configuration.apply(update: try json(#"{"sessionUpdate":"current_mode_update","currentModeId":"old"}"#)))
    }

    func testActiveLegacySurvivesEffortReplacementAndEmptySnapshot() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], modes: try legacy())
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"current_mode_update","currentModeId":"unlisted"}"#)))
        let activeLegacy = try XCTUnwrap(configuration.permissionMode)
        XCTAssertEqual(activeLegacy.route, .legacyMode)

        configuration.apply(configOptions: [select(id: "effort", current: "high", options: [choice("high")])])
        XCTAssertEqual(configuration.permissionMode, activeLegacy)
        XCTAssertEqual(configuration.effort?.currentValue, "high")
        XCTAssertEqual(configuration.effort?.choices.map(\.value), ["high"])

        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"config_option_update","configOptions":[]}"#)))
        XCTAssertEqual(configuration.permissionMode, activeLegacy)
        XCTAssertNil(configuration.effort)
        configuration.apply(configOptions: [])
        XCTAssertEqual(configuration.permissionMode, activeLegacy)
    }

    func testModernSwitchThenRemovalDoesNotReviveLegacy() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], modes: try legacy())
        configuration.apply(configOptions: [select()])
        XCTAssertEqual(configuration.permissionMode?.route, .config("mode"))
        XCTAssertNil(configuration.effort)
        configuration.apply(configOptions: [])
        XCTAssertNil(configuration.permissionMode)
        configuration.apply(configOptions: [select(id: "effort")])
        XCTAssertNil(configuration.permissionMode)
    }

    func testInvalidModernCandidatesDiscardActiveLegacyWithoutRevival() throws {
        for candidates in [
            [select(), select()],
            [select(), select(id: "other", category: .string("mode"))],
            [select(type: "boolean")],
            [select(options: [choice("a"), choice("a")])]
        ] {
            var configuration = SessionConfiguration(configOptions: [select(id: "effort")], modes: try legacy())
            XCTAssertEqual(configuration.permissionMode?.route, .legacyMode)
            configuration.apply(configOptions: candidates)
            XCTAssertNil(configuration.permissionMode)
            configuration.apply(configOptions: [])
            XCTAssertNil(configuration.permissionMode)
            configuration.apply(configOptions: [select(id: "effort")])
            XCTAssertNil(configuration.permissionMode)
            XCTAssertFalse(configuration.apply(update: try json(#"{"sessionUpdate":"current_mode_update","currentModeId":"old"}"#)))
        }
    }

    func testMalformedAndUnrelatedUpdatesDoNotMutateState() throws {
        var configuration = SessionConfiguration(configOptions: [select()])
        let original = configuration
        for text in [
            #"null"#,
            #"{"sessionUpdate":"config_option_update"}"#,
            #"{"sessionUpdate":"config_option_update","configOptions":{}}"#,
            #"{"sessionUpdate":"other","configOptions":[]}"#,
            #"{"sessionUpdate":"current_mode_update","currentModeId":"old"}"#
        ] {
            XCTAssertFalse(configuration.apply(update: try json(text)))
            XCTAssertEqual(configuration, original)
        }
        XCTAssertTrue(configuration.apply(update: .object([
            "sessionUpdate": .string("config_option_update"), "configOptions": .array([select()])
        ])))
        XCTAssertEqual(configuration, original)
    }

    func testUnknownAndMalformedControlsAreExcluded() throws {
        XCTAssertEqual(SessionConfiguration(configOptions: [
            .null, select(id: "unknown"), select(id: "mode", type: "boolean"),
            select(id: "effort", type: "text")
        ]), SessionConfiguration())
        for key in ["id", "name", "type", "currentValue", "options"] {
            guard case var .object(option) = select() else { return XCTFail("Expected object") }
            option.removeValue(forKey: key)
            XCTAssertNil(SessionConfiguration(configOptions: [.object(option)]).permissionMode, key)
            option[key] = .integer(1)
            XCTAssertNil(SessionConfiguration(configOptions: [.object(option)]).permissionMode, key)
        }
        XCTAssertNil(SessionConfiguration(configOptions: [select(type: "boolean")], modes: try legacy()).permissionMode)
    }

    func testMalformedChoicesAndGroupsAreSkipped() throws {
        let picker = SessionConfiguration(configOptions: [select(options: [
            .null, .integer(1), .object(["value": .string("missing-name")]),
            .object(["value": .bool(true), "name": .string("Bad")]),
            try json(#"{"group":"bad","options":[{"value":"hidden","name":"Hidden"}]}"#),
            try json(#"{"name":"Bad group","options":[{"value":"hidden","name":"Hidden"}]}"#),
            choice("valid")
        ])]).permissionMode
        XCTAssertEqual(picker?.choices.map(\.value), ["valid"])
    }

    func testDuplicateIDsAndSemanticKindsAreRejected() throws {
        for options in [
            [select(), select()],
            [select(), select(id: "other", category: .string("mode"))],
            [select(), select(category: .string("unknown"), type: "boolean")],
            [select(id: "effort"), select(id: "reasoning_effort")]
        ] {
            let configuration = SessionConfiguration(configOptions: options)
            XCTAssertNil(configuration.permissionMode)
            XCTAssertNil(configuration.effort)
        }
        XCTAssertNil(SessionConfiguration(configOptions: [select(), select()], modes: try legacy()).permissionMode)
        let configuration = SessionConfiguration(configOptions: [select(), select(), select(id: "effort")])
        XCTAssertNotNil(configuration.effort)
    }

    func testDuplicateValuesIncludingAcrossGroupsAndLegacyAreRejected() throws {
        XCTAssertNil(SessionConfiguration(configOptions: [select(options: [choice("a"), choice("a", name: "Other")])]).permissionMode)
        let group = try json(#"{"group":"g","name":"Group","options":[{"value":"a","name":"Alpha"}]}"#)
        XCTAssertNil(SessionConfiguration(configOptions: [select(options: [group, group])]).permissionMode)
        let models = try json(#"{"currentModeId":"a","availableModes":[{"id":"a","name":"Alpha"},{"id":"a","name":"Other"}]}"#)
        XCTAssertNil(SessionConfiguration(modes: models).permissionMode)
    }

    func testMalformedLegacyAndUnavailableCurrentMode() throws {
        for text in [#"null"#, #"{}"#, #"{"availableModes":[]}"#, #"{"currentModeId":"a","availableModes":false}"#] {
            XCTAssertNil(SessionConfiguration(modes: try json(text)).permissionMode)
        }
        let models = try json(#"{"currentModeId":"missing","availableModes":[null,{"id":"bad"},{"id":"a","name":"Alpha"}]}"#)
        let picker = SessionConfiguration(modes: models).permissionMode
        XCTAssertEqual(picker?.currentValue, "missing")
        XCTAssertEqual(picker?.choices.map(\.value), ["a"])
    }
}
