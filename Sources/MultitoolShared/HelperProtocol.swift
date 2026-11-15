import Foundation

/// The read-only service the privileged helper offers to Multitool over XPC.
/// Nothing here changes the system: the helper only reads counters that macOS
/// keeps for every process and that a normal user cannot read for root's.
@objc public protocol MonitorHelperProtocol {
    /// Protocol version and the helper's executable modification date, so the
    /// app can tell an old helper still running after an update.
    func identity(reply: @escaping (Int, Double) -> Void)

    /// One sample of every process, JSON-encoded `ProcessSnapshot`.
    func snapshot(reply: @escaping (Data) -> Void)

    /// Asks the helper to exit, so launchd starts the up-to-date binary on the
    /// next request. Used after an update.
    func exitForUpdate()
}

public enum HelperIdentity {
    public static let protocolVersion = 1
    public static let label = "com.mmengual.multitool.helper"
    public static let machService = "com.mmengual.multitool.helper"
    public static let plistName = "com.mmengual.multitool.helper.plist"
    public static let teamID = "UGUP3H993V"

    /// Only Multitool, signed with this team's certificate, may connect to the helper.
    public static let clientRequirement =
        "identifier \"com.mmengual.multitool\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    /// And the app only talks to a helper signed the same way.
    public static let helperRequirement =
        "identifier \"\(label)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}
