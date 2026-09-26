/// Facts about this build, recorded in artifact headers and printed by `bikeride-data version`.
public enum BuildInfo {
    public static let toolVersion = "0.1.0"

    /// The compiler's major.minor version, e.g. `6.0`.
    #if compiler(>=6.4)
    public static let swiftVersion = "6.4"
    #elseif compiler(>=6.3)
    public static let swiftVersion = "6.3"
    #elseif compiler(>=6.2)
    public static let swiftVersion = "6.2"
    #elseif compiler(>=6.1)
    public static let swiftVersion = "6.1"
    #else
    public static let swiftVersion = "6.0"
    #endif
}
