import Foundation
import LatchACP
import XCTest
@testable import LatchMacUI

final class SessionConfigurationTests: XCTestCase {
    private func json(_ text: String) throws -> ACPJSONValue {
        try JSONDecoder().decode(ACPJSONValue.self, from: Data(text.utf8))
    }

    private func select(
        id: String = "model", category: ACPJSONValue? = nil,
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
        try json(#"{"currentModelId":"old","availableModels":[{"modelId":"old","name":"Old","description":"Legacy help"}]}"#)
    }

    func testModernCategoriesUseActualConfigIDsAndPreferModernModel() throws {
        let configuration = SessionConfiguration(configOptions: [
            select(id: "vendor-model", category: .string("model")),
            select(id: "vendor-thinking", category: .string("thought_level"), current: "high",
                   options: [choice("high", name: "High")])
        ], models: try legacy())
        XCTAssertEqual(configuration[.model]?.route, .config("vendor-model"))
        XCTAssertEqual(configuration.model?.description, "Selector help")
        XCTAssertEqual(configuration.model?.choices, [
            .init(value: "a", name: "Alpha", description: "Choice help", group: nil)
        ])
        XCTAssertEqual(configuration[.effort]?.route, .config("vendor-thinking"))
        XCTAssertEqual(configuration.effort?.currentValue, "high")
    }

    func testCategoryIsAuthoritativeAndAbsentCategorySupportsKnownIDs() {
        for id in ["effort", "reasoning_effort", "thought_level"] {
            XCTAssertEqual(SessionConfiguration(configOptions: [select(id: id)]).effort?.route, .config(id))
        }
        XCTAssertNotNil(SessionConfiguration(configOptions: [select(category: .null)]).model)
        for category: ACPJSONValue in [.string("mode"), .string("unknown"), .integer(3)] {
            XCTAssertNil(SessionConfiguration(configOptions: [select(category: category)]).model)
        }
        let overridden = SessionConfiguration(configOptions: [select(id: "model", category: .string("thought_level"))])
        XCTAssertNil(overridden.model)
        XCTAssertEqual(overridden.effort?.route, .config("model"))
    }

    func testGroupedOptionsUseDisplayHeadersAndPreserveOrder() throws {
        let groups = try json(#"[{"group":"provider-id","name":"Provider","options":[{"value":"a","name":"Alpha","description":"Help"},null,{"value":"b","name":"Beta"}]},{"group":"other-id","name":"Other","options":[{"value":"c","name":"Gamma"}]}]"#)
        guard case let .array(options) = groups else { return XCTFail("Expected array") }
        let picker = try XCTUnwrap(SessionConfiguration(configOptions: [select(options: options)]).model)
        XCTAssertEqual(picker.choices, [
            .init(value: "a", name: "Alpha", description: "Help", group: "Provider"),
            .init(value: "b", name: "Beta", description: nil, group: "Provider"),
            .init(value: "c", name: "Gamma", description: nil, group: "Other")
        ])
    }

    func testUnavailableCurrentValueAndEmptyOptionsAreNotInvented() {
        let picker = SessionConfiguration(configOptions: [select(current: "missing")]).model
        XCTAssertEqual(picker?.currentValue, "missing")
        XCTAssertEqual(picker?.choices.map(\.value), ["a"])
        let empty = SessionConfiguration(configOptions: [select(current: "missing", options: [])]).model
        XCTAssertEqual(empty?.currentValue, "missing")
        XCTAssertEqual(empty?.choices, [])
    }

    func testLegacyFallbackAndCurrentModelUpdate() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], models: try legacy())
        XCTAssertEqual(configuration.model?.route, .legacyModel)
        XCTAssertEqual(configuration.model?.choices, [
            .init(value: "old", name: "Old", description: "Legacy help", group: nil)
        ])
        XCTAssertNotNil(configuration.effort)
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"current_model_update","currentModelId":"unlisted"}"#)))
        XCTAssertEqual(configuration.model?.currentValue, "unlisted")
        XCTAssertEqual(configuration.model?.choices.map(\.value), ["old"])
    }

    func testFullReplacementRemovesPickersWithoutResurrectingLegacy() throws {
        var configuration = SessionConfiguration(configOptions: [select(), select(id: "effort")], models: try legacy())
        configuration.apply(configOptions: [select(id: "effort", current: "new")])
        XCTAssertNil(configuration.model)
        XCTAssertEqual(configuration.effort?.currentValue, "new")
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"config_option_update","configOptions":[]}"#)))
        XCTAssertEqual(configuration, SessionConfiguration())
        XCTAssertFalse(configuration.apply(update: try json(#"{"sessionUpdate":"current_model_update","currentModelId":"old"}"#)))
    }

    func testActiveLegacySurvivesEffortReplacementAndEmptySnapshot() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], models: try legacy())
        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"current_model_update","currentModelId":"unlisted"}"#)))
        let activeLegacy = try XCTUnwrap(configuration.model)
        XCTAssertEqual(activeLegacy.route, .legacyModel)

        configuration.apply(configOptions: [select(id: "effort", current: "high", options: [choice("high")])])
        XCTAssertEqual(configuration.model, activeLegacy)
        XCTAssertEqual(configuration.effort?.currentValue, "high")
        XCTAssertEqual(configuration.effort?.choices.map(\.value), ["high"])

        XCTAssertTrue(configuration.apply(update: try json(#"{"sessionUpdate":"config_option_update","configOptions":[]}"#)))
        XCTAssertEqual(configuration.model, activeLegacy)
        XCTAssertNil(configuration.effort)
        configuration.apply(configOptions: [])
        XCTAssertEqual(configuration.model, activeLegacy)
    }

    func testModernSwitchThenRemovalDoesNotReviveLegacy() throws {
        var configuration = SessionConfiguration(configOptions: [select(id: "effort")], models: try legacy())
        configuration.apply(configOptions: [select()])
        XCTAssertEqual(configuration.model?.route, .config("model"))
        XCTAssertNil(configuration.effort)
        configuration.apply(configOptions: [])
        XCTAssertNil(configuration.model)
        configuration.apply(configOptions: [select(id: "effort")])
        XCTAssertNil(configuration.model)
    }

    func testInvalidModernCandidatesDiscardActiveLegacyWithoutRevival() throws {
        for candidates in [
            [select(), select()],
            [select(), select(id: "other", category: .string("model"))],
            [select(type: "boolean")],
            [select(options: [choice("a"), choice("a")])]
        ] {
            var configuration = SessionConfiguration(configOptions: [select(id: "effort")], models: try legacy())
            XCTAssertEqual(configuration.model?.route, .legacyModel)
            configuration.apply(configOptions: candidates)
            XCTAssertNil(configuration.model)
            configuration.apply(configOptions: [])
            XCTAssertNil(configuration.model)
            configuration.apply(configOptions: [select(id: "effort")])
            XCTAssertNil(configuration.model)
            XCTAssertFalse(configuration.apply(update: try json(#"{"sessionUpdate":"current_model_update","currentModelId":"old"}"#)))
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
            #"{"sessionUpdate":"current_model_update","currentModelId":"old"}"#
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
            .null, select(id: "unknown"), select(id: "model", type: "boolean"),
            select(id: "effort", type: "text")
        ]), SessionConfiguration())
        for key in ["id", "name", "type", "currentValue", "options"] {
            guard case var .object(option) = select() else { return XCTFail("Expected object") }
            option.removeValue(forKey: key)
            XCTAssertNil(SessionConfiguration(configOptions: [.object(option)]).model, key)
            option[key] = .integer(1)
            XCTAssertNil(SessionConfiguration(configOptions: [.object(option)]).model, key)
        }
        XCTAssertNil(SessionConfiguration(configOptions: [select(type: "boolean")], models: try legacy()).model)
    }

    func testMalformedChoicesAndGroupsAreSkipped() throws {
        let picker = SessionConfiguration(configOptions: [select(options: [
            .null, .integer(1), .object(["value": .string("missing-name")]),
            .object(["value": .bool(true), "name": .string("Bad")]),
            try json(#"{"group":"bad","options":[{"value":"hidden","name":"Hidden"}]}"#),
            try json(#"{"name":"Bad group","options":[{"value":"hidden","name":"Hidden"}]}"#),
            choice("valid")
        ])]).model
        XCTAssertEqual(picker?.choices.map(\.value), ["valid"])
    }

    func testDuplicateIDsAndSemanticKindsAreRejected() throws {
        for options in [
            [select(), select()],
            [select(), select(id: "other", category: .string("model"))],
            [select(), select(category: .string("unknown"), type: "boolean")],
            [select(id: "effort"), select(id: "reasoning_effort")]
        ] {
            let configuration = SessionConfiguration(configOptions: options)
            XCTAssertNil(configuration.model)
            XCTAssertNil(configuration.effort)
        }
        XCTAssertNil(SessionConfiguration(configOptions: [select(), select()], models: try legacy()).model)
        let configuration = SessionConfiguration(configOptions: [select(), select(), select(id: "effort")])
        XCTAssertNotNil(configuration.effort)
    }

    func testDuplicateValuesIncludingAcrossGroupsAndLegacyAreRejected() throws {
        XCTAssertNil(SessionConfiguration(configOptions: [select(options: [choice("a"), choice("a", name: "Other")])]).model)
        let group = try json(#"{"group":"g","name":"Group","options":[{"value":"a","name":"Alpha"}]}"#)
        XCTAssertNil(SessionConfiguration(configOptions: [select(options: [group, group])]).model)
        let models = try json(#"{"currentModelId":"a","availableModels":[{"modelId":"a","name":"Alpha"},{"modelId":"a","name":"Other"}]}"#)
        XCTAssertNil(SessionConfiguration(models: models).model)
    }

    func testMalformedLegacyAndUnavailableCurrentModel() throws {
        for text in [#"null"#, #"{}"#, #"{"availableModels":[]}"#, #"{"currentModelId":"a","availableModels":false}"#] {
            XCTAssertNil(SessionConfiguration(models: try json(text)).model)
        }
        let models = try json(#"{"currentModelId":"missing","availableModels":[null,{"modelId":"bad"},{"modelId":"a","name":"Alpha"}]}"#)
        let picker = SessionConfiguration(models: models).model
        XCTAssertEqual(picker?.currentValue, "missing")
        XCTAssertEqual(picker?.choices.map(\.value), ["a"])
    }
}
