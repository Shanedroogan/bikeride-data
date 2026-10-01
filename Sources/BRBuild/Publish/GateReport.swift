import Foundation

/// The validation gate's verdict on a set.
public enum GateStatus: String, Codable, Sendable, Equatable {
    /// Every check passed: publish.
    case pass
    /// Only fail-soft checks failed (a system with under 3 days of coverage): publish, with that
    /// system marked `noSchedule`; the relay's health check turns the short coverage into the alert.
    case softFail
    /// A hard check failed: publish nothing (no manifest, no heartbeat), so the previous set stays
    /// current. `bikeride-data gate` exits 3.
    case fail
}

public enum GateCheckStatus: String, Codable, Sendable, Equatable {
    case pass, softFail, fail
    /// Not applicable to this run (no previous build to compare with, an artifact carried
    /// forward unchanged and checked when it was built).
    case skipped
}

/// A system's schedule status in the set: what manifest `systems.<s>.status` records.
public enum SetSystemStatus: String, Codable, Sendable, Equatable {
    case ok
    /// Coverage from the build day is shorter than the gate's minimum (fail soft). The real dates
    /// stay in manifest `coverage`.
    case noSchedule
}

/// One check's result in `reports/gate.json`.
public struct GateCheckResult: Codable, Sendable, Equatable {
    public var name: String
    public var status: GateCheckStatus
    public var summary: String
    public var failures: [String] = []
    public var warnings: [String] = []
    /// Accepted exceptions and facts worth reading: allowlisted stops, per-region shares.
    public var notes: [String] = []
    public var metrics: [String: Double] = [:]
    public var seconds = 0.0

    public init(name: String, status: GateCheckStatus, summary: String, failures: [String] = [], warnings: [String] = [],
                notes: [String] = [], metrics: [String: Double] = [:]) {
        self.name = name
        self.status = status
        self.summary = summary
        self.failures = failures
        self.warnings = warnings
        self.notes = notes
        self.metrics = metrics
    }

    /// `fail` when there are failures, else `pass` (or `skipped` when nothing was checked).
    static func verdict(_ name: String, checked: Bool, summary: String, failures: [String], warnings: [String] = [],
                        notes: [String] = [], metrics: [String: Double] = [:]) -> GateCheckResult {
        GateCheckResult(name: name, status: !failures.isEmpty ? .fail : checked ? .pass : .skipped, summary: summary,
                        failures: failures, warnings: warnings, notes: notes, metrics: metrics)
    }
}

/// Per system: schedule status and coverage from the build day.
public struct GateSystem: Codable, Sendable, Equatable {
    public var status: SetSystemStatus
    /// Consecutive covered days from the build day (the relay's count).
    public var coverageDays: Int
    /// Covered dates in the set, and the first and last (`YYYY-MM-DD`).
    public var dates: Int
    public var first: String?
    public var last: String?

    public init(status: SetSystemStatus, coverageDays: Int, dates: Int, first: String?, last: String?) {
        self.status = status
        self.coverageDays = coverageDays
        self.dates = dates
        self.first = first
        self.last = last
    }
}

/// `reports/gate.json`: written by every gate run, passing or not. The manifest requires one whose
/// `status` is not `fail` and whose `artifacts` and `blobs` equal the set's raw and `.xz` hashes,
/// so no manifest is ever written for bytes the gate did not pass.
public struct GateReport: Codable, Sendable, Equatable {
    public static let fileName = "gate.json"

    public var schema = 1
    public var generatedAt: String
    public var tool: String
    /// `YYYYMMDD`.
    public var buildDay: String
    public var status: GateStatus
    /// The artifacts checked, as found in the data directory: name → rawSha256.
    public var artifacts: [String: String]
    /// Their `.xz` blobs: name → SHA-256 of the blob (the manifest's `sha`).
    public var blobs: [String: String]
    /// Artifacts not in the data directory that the previous manifest supplies (not re-checked).
    public var carriedForward: [String]
    public var previousSetId: String?
    /// The systems named by `--accept-trip-count-change` for this run (sorted), whose trip-count
    /// changes beyond the limit the `tripCounts` check reported as accepted warnings rather than
    /// failures. Absent when the flag was not given. The workflow's step summary shows it.
    public var acceptedTripCountChange: [String]?
    public var systems: [String: GateSystem]
    public var checks: [GateCheckResult]

    public func check(_ name: String) -> GateCheckResult? { checks.first { $0.name == name } }

    public static func load(_ url: URL) throws -> GateReport {
        try JSONDecoder().decode(GateReport.self, from: Data(contentsOf: url))
    }
}
