import BRConfig
import BRCore
import BRData
import BRFlows
import BRTimetable
import Foundation

extension Gate {
    /// The checks every published set runs after the built-in ones (`bikeride-data gate` and
    /// `all` pass them as ``extraChecks``): the config's cross-artifact reference checks and the
    /// flows statistics. Not on by default in ``Gate``, so a set whose config is not about its
    /// timetables (a unit-test lattice built from the repository's `Data/`) can still be gated.
    public static var publishHooks: [any GateCheck] { [ConfigReferencesCheck(), FlowsStatisticsCheck()] }
}

/// `configReferences`: ``ReferenceChecks`` over the set's `config.bin`, `tt-*` and `stations`, on
/// every build, because the timetables change twice a day while config is rebuilt only when
/// `Data/` changes. Every LIRR stop with service has a fare zone and every NYC terminal is served;
/// every MTA station pair and SIR entry names stations of the subway feed; every fixed transfer
/// resolves; every valet station is in `stations.bin` within 50 m of its listed coordinate; every
/// station's region is configured. An error in any fails the set. (The Citi Bike price drift
/// warning stays in the config build: the gate has no GBFS pricing plans.)
///
/// A config carried forward from the previous manifest cannot be read here. When any `tt-*` or
/// `stations` is new in the data directory, the check fails: the new artifacts would go out
/// unchecked against the config, so a job that rebuilds them keeps `config.bin` and
/// `config.bin.xz` in its data directory (a raw file without its blob fails the `xz` check and
/// the manifest). When nothing it references is new either, it is skipped. A check whose input is
/// carried forward (config new, a timetable not) is skipped with a warning: the config build ran
/// it against the set it was built with.
public struct ConfigReferencesCheck: GateCheck {
    public var name: String { "configReferences" }

    /// The artifacts the reference checks read.
    public static let referencedKinds: [ArtifactKind] = [.stations] + TransitSystem.allCases.map(ArtifactKind.timetable(for:))

    public init() {}

    public func run(_ context: GateContext) throws -> GateCheckResult {
        guard let config = try context.config() else {
            guard context.carriedForward.contains(.config) else {
                return GateCheckResult(name: name, status: .skipped, summary: "no config.bin in the set (the artifacts check fails a set without one)")
            }
            let fresh = Self.referencedKinds.filter { context.artifacts[$0] != nil }.map(\.name)
            guard !fresh.isEmpty else {
                return GateCheckResult(name: name, status: .skipped,
                                       summary: "config and everything it references are carried forward from set \(context.previousSetId); checked when they were built")
            }
            return GateCheckResult(
                name: name, status: .fail, summary: "cannot check the new artifacts against a carried-forward config",
                failures: ["config.bin is carried forward from set \(context.previousSetId), but \(fresh.joined(separator: ", ")) are new: "
                    + "the reference checks need config.bin in the data directory"])
        }
        var timetables: [TransitSystem: Timetable] = [:]
        for system in TransitSystem.allCases {
            if let timetable = try context.timetable(system) { timetables[system] = timetable }
        }
        let checks = ReferenceChecks.run(config.document, inputs: .init(timetables: timetables, stations: try context.stations(), pricingPlans: nil))
            .filter { $0.name != "citiBikePricing" }
        var failures: [String] = [], warnings: [String] = [], notes: [String] = [], metrics: [String: Double] = [:]
        for check in checks {
            failures += check.errors.map { "\(check.name): \($0)" }
            warnings += check.warnings.map { "\(check.name): \($0)" }
            if let reason = check.skipped {
                let carried = context.carriedForward.filter(Self.referencedKinds.contains).map(\.name)
                warnings.append("\(check.name) not checked: \(reason)" + (carried.isEmpty ? "" : " (carried forward: \(carried.joined(separator: ", ")))"))
            } else {
                notes.append("\(check.name): \(check.checked) checked, \(check.errors.count) error(s)")
                metrics["\(check.name).checked"] = Double(check.checked)
            }
        }
        let ran = checks.filter { $0.skipped == nil }
        return .verdict(name, checked: !ran.isEmpty,
                        summary: failures.isEmpty ? "\(ran.count) reference checks pass (\(checks.count - ran.count) skipped)"
                                                  : "\(failures.count) reference error(s) in \(ran.filter { !$0.errors.isEmpty }.map(\.name).joined(separator: ", "))",
                        failures: failures, warnings: warnings, notes: notes, metrics: metrics)
    }
}

/// `flows`: the flows statistics. A `flows.bin` in the data directory must be the one
/// `reports/flows.json` describes (outcome `built`, same rawSha256), and the report's figures
/// must pass ``FlowsGate`` again: unmatched trip ends in the newest month under 2 % and over the
/// window under 5 % per system and side, dropped trip ends, empty days, saturated counters, month
/// row counts. The same rule as `streets`: a `flows.bin` no report vouches for fails, unless it is
/// the previous set's, unchanged (checked when it was built); then the check is skipped.
///
/// A flows build whose own gate failed (`flows` exit 3) keeps the older flows.bin and its report
/// and writes `reports/flows-failed.json` (``FlowsReport/record(at:)``): the older file is checked
/// against its own report as before and may go out again, with the failed build as a warning, so
/// flows fails soft. (A `flows.json` that is itself gate-failed, from a builder before that file
/// existed, vouches for nothing.)
///
/// Without a `flows.bin`: carried forward, skipped; absent, skipped with a warning (the set
/// publishes without flows; the artifacts check fails it when flows is required).
public struct FlowsStatisticsCheck: GateCheck {
    public var name: String { "flows" }
    public static let reportFileName = "flows.json"

    public init() {}

    public func run(_ context: GateContext) throws -> GateCheckResult {
        let reportURL = context.reportsDirectory.appendingPathComponent(Self.reportFileName)
        func load(_ url: URL) -> (report: FlowsReport?, unreadable: String?) {
            guard FileManager.default.fileExists(atPath: url.path) else { return (nil, nil) }
            do {
                return (try JSONDecoder().decode(FlowsReport.self, from: Data(contentsOf: url)), nil)
            } catch {
                return (nil, "reports/\(url.lastPathComponent) does not read (\(error))")
            }
        }
        let (report, unreadable) = load(reportURL)
        func failure(_ report: FlowsReport) -> String {
            "the last flows build (\(report.generatedAt)) failed its gate: "
                + (report.gate.failures.isEmpty ? report.reason ?? "no reason given" : report.gate.failures.joined(separator: "; "))
        }
        let failedURL = FlowsReport.failedReportURL(for: reportURL)
        let failed = load(failedURL)
        let lastBuildFailed: [String]
        if let problem = failed.unreadable {
            lastBuildFailed = [problem]
        } else if let failedBuild = failed.report {
            lastBuildFailed = [failure(failedBuild) + " (reports/\(failedURL.lastPathComponent))"]
        } else if let report, report.outcome == .gateFailed {
            lastBuildFailed = [failure(report)]
        } else {
            lastBuildFailed = []
        }

        guard let local = context.artifacts[.flows] else {
            if context.carriedForward.contains(.flows) {
                return GateCheckResult(name: name, status: .skipped, summary: "flows carried forward from set \(context.previousSetId); checked when it was built",
                                       warnings: lastBuildFailed)
            }
            return GateCheckResult(name: name, status: .skipped, summary: "no flows.bin: the set publishes without flows",
                                   warnings: ["the set has no flows.bin (not required; --require-flows makes it a failure)"] + lastBuildFailed)
        }
        _ = try context.flows()   // opens and validates (the artifacts check reports a failure too)

        if let report, report.outcome == .built, let artifact = report.artifact, artifact.rawSha256 == local.rawSha256 {
            let gate = FlowsGate.evaluate(report, baseline: report.baselineMonthRows)
            var failures = gate.failures, notes: [String] = [], metrics: [String: Double] = [:]
            if !report.gate.passed, failures.isEmpty { failures.append("reports/\(Self.reportFileName) says its gate did not pass") }
            for system in report.systems {
                let key = system.system.rawValue
                metrics["\(key).newestMonthUnmatchedStartPercent"] = Self.percent(system.newestMonthStartSide.stats.unmatchedShare)
                metrics["\(key).newestMonthUnmatchedEndPercent"] = Self.percent(system.newestMonthEndSide.stats.unmatchedShare)
                metrics["\(key).windowUnmatchedStartPercent"] = Self.percent(system.startSide.stats.unmatchedShare)
                metrics["\(key).windowUnmatchedEndPercent"] = Self.percent(system.endSide.stats.unmatchedShare)
                notes.append(String(format: "%@ %@: %.3f%% / %.3f%% of start / end ids unmatched (window %.3f%% / %.3f%%)", key,
                                    system.newestMonth.yyyymm, 100 * system.newestMonthStartSide.stats.unmatchedShare,
                                    100 * system.newestMonthEndSide.stats.unmatchedShare, 100 * system.startSide.stats.unmatchedShare,
                                    100 * system.endSide.stats.unmatchedShare))
            }
            metrics["keys"] = Double(report.gbfs?.keys ?? 0)
            return .verdict(name, checked: true,
                            summary: failures.isEmpty ? "flows.bin \(report.months.map(\.yyyymm).joined(separator: "-")) passes the flows gate again"
                                                      : "\(failures.count) flows statistic(s) fail",
                            failures: failures, warnings: lastBuildFailed, notes: notes, metrics: metrics)
        }

        let why = unreadable ?? report.map { report in
            report.outcome != .built ? "reports/\(Self.reportFileName) is from a flows build that wrote nothing (\(report.outcome.rawValue))"
                : "reports/\(Self.reportFileName) describes another flows.bin"
        } ?? "no reports/\(Self.reportFileName)"
        if let previous = context.previous?.artifacts[ArtifactKind.flows.name], previous.rawSha256 == local.rawSha256 {
            return GateCheckResult(name: name, status: .skipped, summary: "flows.bin unchanged since set \(context.previousSetId); checked when it was built",
                                   warnings: [why] + lastBuildFailed)
        }
        return GateCheckResult(name: name, status: .fail, summary: "no flows report vouches for this flows.bin", failures: lastBuildFailed + [why])
    }

    static func percent(_ share: Double) -> Double { (share * 100_000).rounded() / 1000 }
}
