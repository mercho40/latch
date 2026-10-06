import LatchRemoteProtocol
import UIKit
import XCTest
@testable import LatchiOSUI

/// The camera is not in the Simulator, so these feed the scanner what a code would hold.
@MainActor
final class PairingScannerTests: XCTestCase {
    private let token = LatchRemoteToken.generate()

    func testAPairingCodeEndsTheScanOnce() throws {
        let scanner = PairingScannerViewController(state: .scanning)
        var scanned: [LatchRemotePairing] = []
        scanner.onScan = { scanned.append($0) }
        scanner.loadViewIfNeeded()
        scanner.handle(payload: "latch://latch.example.com:443?transport=wss&token=\(token.rawValue)\n")
        XCTAssertEqual(scanned, [try LatchRemotePairing(host: "latch.example.com", transport: .webSocket, token: token)])
        scanner.handle(payload: "latch://other.example?token=\(token.rawValue)")
        XCTAssertEqual(scanned.count, 1, "One code per scan: the sheet it opens confirms one server")
    }

    /// Another code says why it is not one, once while it stays in view, and scanning goes on.
    func testAnyOtherCodeSaysWhyAndScanningGoesOn() throws {
        let scanner = PairingScannerViewController(state: .scanning)
        var scanned: [LatchRemotePairing] = []
        scanner.onScan = { scanned.append($0) }
        scanner.loadViewIfNeeded()
        XCTAssertEqual(scanner.hintLabel.text, "Point the camera at the code “latch-server pair --qr” shows.")
        scanner.handle(payload: "https://example.com/menu")
        XCTAssertEqual(scanner.hint, "That isn’t a Latch pairing code. Scan the one “latch-server pair --qr” shows.")
        XCTAssertEqual(scanner.hintLabel.text, scanner.hint)
        scanner.handle(payload: "latch://vps.example")
        XCTAssertEqual(scanner.hint, "This code can’t add a server. It has no token. Run “latch-server pair” on the server for a complete link.")
        XCTAssertTrue(scanned.isEmpty)
        scanner.handle(payload: "latch://vps.example?token=\(token.rawValue)")
        XCTAssertEqual(scanned.count, 1)
    }

    /// Where the camera cannot scan, the screen says why and how else to pair.
    func testEachWayTheCameraCannotScanIsExplained() throws {
        XCTAssertNil(PairingScannerViewController.configuration(for: .scanning))
        XCTAssertNil(PairingScannerViewController.configuration(for: .asking))
        let unsupported = try XCTUnwrap(PairingScannerViewController.configuration(for: .unsupported))
        XCTAssertEqual(unsupported.text, "Scanning Isn’t Available")
        XCTAssertTrue(unsupported.secondaryText?.contains("Camera app") == true)
        let denied = try XCTUnwrap(PairingScannerViewController.configuration(for: .denied))
        XCTAssertEqual(denied.text, "Camera Access Is Off")
        XCTAssertEqual(denied.button.title, "Open Settings")
        let restricted = try XCTUnwrap(PairingScannerViewController.configuration(for: .restricted))
        XCTAssertEqual(restricted.text, "Camera Restricted")
        XCTAssertTrue(restricted.secondaryText?.contains("Paste the link") == true)

        let scanner = PairingScannerViewController(state: .denied)
        let navigation = UINavigationController(rootViewController: scanner)
        scanner.loadViewIfNeeded()
        XCTAssertEqual((scanner.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text,
                       "Camera Access Is Off")
        XCTAssertEqual(navigation.overrideUserInterfaceStyle, .unspecified, "Explanations follow the system's appearance")
        let scanning = PairingScannerViewController(state: .scanning)
        let camera = UINavigationController(rootViewController: scanning)
        scanning.loadViewIfNeeded()
        XCTAssertNil(scanning.contentUnavailableConfiguration)
        XCTAssertEqual(camera.overrideUserInterfaceStyle, .dark, "Over the camera the bar is dark")
    }

    #if targetEnvironment(simulator)
    func testTheSimulatorCannotScan() {
        XCTAssertEqual(PairingScannerViewController.availability(), .unsupported)
    }
    #endif
}
