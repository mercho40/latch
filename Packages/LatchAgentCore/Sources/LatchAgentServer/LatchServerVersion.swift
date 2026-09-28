/// The version `latch-server --version` prints and the welcome reports. Bump it by hand with
/// `MARKETING_VERSION` in Apps/LatchMac/Configuration/App.xcconfig and AgentService.xcconfig
/// and Apps/LatchiOS/Configuration/App.xcconfig, so a server and the apps from one release
/// agree; Scripts/release.sh refuses a release when they differ.
public enum LatchServerVersion {
    public static let current = "0.2.0"
}
