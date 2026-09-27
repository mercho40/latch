/// The version `latch-server --version` prints and the welcome reports. Bump it by hand with
/// `MARKETING_VERSION` in Apps/LatchMac/Configuration/App.xcconfig and AgentService.xcconfig,
/// so a server and the app from one release agree; Scripts/release.sh refuses a release when they differ.
public enum LatchServerVersion {
    public static let current = "0.1.0"
}
