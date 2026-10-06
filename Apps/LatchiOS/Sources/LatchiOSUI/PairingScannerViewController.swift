import AVFoundation
import LatchRemoteProtocol
import UIKit
import VisionKit

/// Scan Pairing Code: the camera, reading the QR code `latch-server pair --qr` draws, so a
/// server is added without leaving Latch for the Camera app. A pairing link ends the scan; any
/// other code says why it is not one, and scanning goes on. Where the camera cannot scan, the
/// screen says why and how else to pair. Scanning connects nowhere: what the code held goes
/// to the same Add Server sheet a tapped link opens.
final class PairingScannerViewController: UIViewController, DataScannerViewControllerDelegate {
    enum State: Equatable {
        /// Waiting for the user to answer the camera prompt.
        case asking
        case scanning
        /// No camera, or one VisionKit cannot scan with, as in the Simulator.
        case unsupported
        case denied
        case restricted
    }

    /// Called once with the pairing the code held, after the scanner has gone.
    var onScan: ((LatchRemotePairing) -> Void)?
    private(set) var state: State
    /// Said over the camera: what to point it at, or why the last code is not one.
    private(set) var hint = PairingScannerViewController.prompt
    private var scanner: DataScannerViewController?
    private var finished = false
    /// The last code that was not a pairing link, so holding it in view warns once.
    private var lastRejected: String?
    let hintLabel = UILabel()
    private let hintBackground: UIVisualEffectView

    static let prompt = "Point the camera at the code “latch-server pair --qr” shows."

    init(state: State = PairingScannerViewController.availability()) {
        self.state = state
        if #available(iOS 26.0, *) {
            hintBackground = UIVisualEffectView(effect: UIGlassEffect())
            hintBackground.cornerConfiguration = .capsule(maximumRadius: 22)
        } else {
            hintBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
            hintBackground.layer.cornerRadius = 22
            hintBackground.layer.cornerCurve = .continuous
            hintBackground.clipsToBounds = true
        }
        super.init(nibName: nil, bundle: nil)
        title = "Scan Pairing Code"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What the camera allows before anything is asked.
    static func availability() -> State {
        guard DataScannerViewController.isSupported else { return .unsupported }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .scanning
        case .notDetermined: return .asking
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    /// The scanner in its own navigation controller, with Cancel.
    static func sheet(onScan: @escaping (LatchRemotePairing) -> Void) -> UINavigationController {
        let scanner = PairingScannerViewController()
        scanner.onScan = onScan
        let navigation = UINavigationController(rootViewController: scanner)
        navigation.modalPresentationStyle = .formSheet
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        hintLabel.font = .preferredFont(forTextStyle: .subheadline)
        hintLabel.adjustsFontForContentSizeCategory = true
        hintLabel.numberOfLines = 0
        hintLabel.textAlignment = .center
        hintLabel.text = hint
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintBackground.contentView.addSubview(hintLabel)
        hintBackground.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintBackground)
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: hintBackground.contentView.leadingAnchor, constant: 18),
            hintLabel.trailingAnchor.constraint(equalTo: hintBackground.contentView.trailingAnchor, constant: -18),
            hintLabel.topAnchor.constraint(equalTo: hintBackground.contentView.topAnchor, constant: 12),
            hintLabel.bottomAnchor.constraint(equalTo: hintBackground.contentView.bottomAnchor, constant: -12),
            hintBackground.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintBackground.leadingAnchor.constraint(greaterThanOrEqualTo: margins.leadingAnchor),
            hintBackground.trailingAnchor.constraint(lessThanOrEqualTo: margins.trailingAnchor),
            hintBackground.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
        ])
        refresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        switch state {
        case .asking: ask()
        case .scanning: startScanning()
        case .unsupported, .denied, .restricted: break
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner?.stopScanning()
    }

    private func ask() {
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.state = granted ? .scanning : .denied
            self.refresh()
            if granted, self.viewIfLoaded?.window != nil { self.startScanning() }
        }
    }

    /// The camera under the hint, started once the screen is up, as VisionKit asks.
    private func startScanning() {
        guard !finished else { return }
        let scanner = self.scanner ?? {
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                    isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
            scanner.delegate = self
            addChild(scanner)
            scanner.view.frame = view.bounds
            scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(scanner.view, at: 0)
            scanner.didMove(toParent: self)
            self.scanner = scanner
            return scanner
        }()
        do {
            try scanner.startScanning()
        } catch let error as DataScannerViewController.ScanningUnavailable {
            unavailable(error)
        } catch {
            state = .unsupported
            refresh()
        }
    }

    private func unavailable(_ error: DataScannerViewController.ScanningUnavailable) {
        state = error == .cameraRestricted ? .restricted : .unsupported
        refresh()
    }

    // MARK: Codes

    /// What a code held. A pairing link ends the scan with it; anything else says why it is
    /// not one, once while it stays in view, and scanning goes on.
    func handle(payload: String) {
        guard !finished else { return }
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let pairing = try LatchRemotePairing(parsing: text)
            finished = true
            scanner?.stopScanning()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            finish(pairing)
        } catch {
            guard text != lastRejected else { return }
            lastRejected = text
            let error = error as? LatchRemotePairingError ?? .invalidScheme
            hint = error == .invalidScheme
                ? "That isn’t a Latch pairing code. Scan the one “latch-server pair --qr” shows."
                : "This code can’t add a server. " + ServerSheets.explanation(error)
            hintLabel.text = hint
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            UIAccessibility.post(notification: .announcement, argument: hint)
        }
    }

    private func finish(_ pairing: LatchRemotePairing) {
        let handler = onScan
        onScan = nil
        if presentingViewController == nil {
            handler?(pairing)
        } else {
            dismiss(animated: true) { handler?(pairing) }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            guard case let .barcode(code) = item, let payload = code.payloadStringValue else { continue }
            handle(payload: payload)
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        guard case let .barcode(code) = item, let payload = code.payloadStringValue else { return }
        lastRejected = nil
        handle(payload: payload)
    }

    func dataScanner(_ dataScanner: DataScannerViewController,
                     becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        unavailable(error)
    }

    // MARK: States

    private func refresh() {
        guard isViewLoaded else { return }
        hintBackground.isHidden = state != .scanning
        contentUnavailableConfiguration = Self.configuration(for: state)
        if state != .scanning, let scanner {
            scanner.stopScanning()
            scanner.willMove(toParent: nil)
            scanner.view.removeFromSuperview()
            scanner.removeFromParent()
            self.scanner = nil
        }
        // Over the camera the bar and the hint are dark whatever the appearance, as in the
        // Camera app; the explanations follow the system's.
        let camera = state == .scanning || state == .asking
        navigationController?.overrideUserInterfaceStyle = camera ? .dark : .unspecified
        view.backgroundColor = camera ? .black : .systemBackground
    }

    /// Why the camera is not scanning, and how else to pair; nil while it is, or about to be.
    static func configuration(for state: State) -> UIContentUnavailableConfiguration? {
        let device = UIDevice.current.model
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "qrcode.viewfinder")
        switch state {
        case .asking, .scanning:
            return nil
        case .unsupported:
            configuration.text = "Scanning Isn’t Available"
            configuration.secondaryText = "This \(device) can’t scan codes in Latch. Scan the code with the Camera app instead, "
                + "or paste the link the server prints in Add Server."
        case .denied:
            configuration.text = "Camera Access Is Off"
            configuration.secondaryText = "Allow Latch to use the camera in Settings to scan pairing codes, "
                + "or paste the link the server prints in Add Server."
            var button = UIButton.Configuration.filled()
            button.title = "Open Settings"
            button.cornerStyle = .capsule
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        case .restricted:
            configuration.text = "Camera Restricted"
            configuration.secondaryText = "A restriction on this \(device) keeps apps from using the camera. "
                + "Paste the link the server prints in Add Server instead."
        }
        return configuration
    }
}
