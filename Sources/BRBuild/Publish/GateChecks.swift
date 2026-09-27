import BRCore
import BRData
import Foundation

/// The gate's checks as functions of plain inputs, so each rule is testable without a built set.
/// ``Gate`` gathers the inputs from the artifacts and calls these.
public enum GateChecks {
    // MARK: xz

    /// Every blob is exactly 1 stream with 1 block (``XZCheck``), and `xz -dc` of it gives the raw
    /// file's size and SHA-256. A missing blob fails. Blobs are checked in parallel.
    public static func xz(_ files: [SetArtifactFile], runner: any ToolRunner) -> GateCheckResult {
        let ordered = files.sorted { $0.kind.name < $1.kind.name }
        let results = ParallelResults<String?>(count: ordered.count)
        DispatchQueue.concurrentPerform(iterations: ordered.count) { index in
            let problem: String?
            do { problem = try blobProblem(ordered[index], runner: runner) } catch { problem = "\(error)" }
            results.set(index, .success(problem))
        }
        var failures: [String] = []
        for (file, problem) in zip(ordered, (try? results.values()) ?? []) {
            if let problem { failures.append("\(file.kind.name): \(problem)") }
        }
        return .verdict("xz", checked: !ordered.isEmpty,
                        summary: "\(ordered.count - failures.count)/\(ordered.count) blobs are one stream, one block and decode to rawSha256",
                        failures: failures, metrics: ["blobs": Double(ordered.count)])
    }

    /// Why `file`'s blob is not publishable, or nil.
    static func blobProblem(_ file: SetArtifactFile, runner: any ToolRunner) throws -> String? {
        guard let xz = file.xzURL else { return "no .xz blob" }
        do {
            try XZCheck.verify(xz, runner: runner)
        } catch {
            return "\(error)"
        }
        let decoded = FileManager.default.temporaryDirectory.appendingPathComponent("bikeride-gate-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: decoded) }
        do {
            try XZProcessCodec(runner: runner).decompress(from: xz, to: decoded, expectedRawBytes: file.rawBytes)
        } catch {
            return "xz -dc: \(error)"
        }
        let sha = try SetArtifacts.sha256(of: decoded, runner: runner)
        return sha == file.rawSha256 ? nil : "decodes to sha256 \(sha), not the raw file's \(file.rawSha256)"
    }

    // MARK: Coverage

    /// Per system, consecutive covered days from `today`. Under `minDays` fails soft: the system is
    /// marked `noSchedule` and keeps its real dates (the relay's 503 on short coverage is the alert).
    public static func coverage(_ coverage: [String: [ServiceDate]], today: ServiceDate, minDays: Int)
        -> (result: GateCheckResult, systems: [String: GateSystem])
    {
        var systems: [String: GateSystem] = [:]
        var short: [String] = [], notes: [String] = [], metrics: [String: Double] = [:]
        for (name, dates) in coverage.sorted(by: { $0.key < $1.key }) {
            let sorted = dates.sorted()
            let days = SetSystems.coverageDays(Set(sorted), from: today)
            let status: SetSystemStatus = days < minDays ? .noSchedule : .ok
            systems[name] = GateSystem(status: status, coverageDays: days, dates: sorted.count,
                                       first: sorted.first.map(SetSystems.isoDay), last: sorted.last.map(SetSystems.isoDay))
            metrics["\(name).coverageDays"] = Double(days)
            notes.append("\(name): \(days) days from \(SetSystems.isoDay(today))" + (sorted.last.map { " (last \(SetSystems.isoDay($0)))" } ?? ""))
            if status == .noSchedule {
                short.append("\(name): \(days) day(s) of coverage from \(SetSystems.isoDay(today)), under \(minDays): marked noSchedule")
            }
        }
        let result = GateCheckResult(
            name: "coverage", status: short.isEmpty ? (coverage.isEmpty ? .skipped : .pass) : .softFail,
            summary: short.isEmpty ? "every system has at least \(minDays) days of coverage" : "\(short.count) system(s) short of \(minDays) days",
            failures: short, notes: notes, metrics: metrics)
        return (result, systems)
    }

    // MARK: Trip counts

    /// Active trips per service date, per system, against the previous build: the same date when
    /// the previous build covered it; otherwise that build's median for the date's weekday
    /// (holidays excluded from every median), and for a date in `holidays` the nearest of the
    /// `holidayProfiles` medians (its weekday, Saturday, Sunday). A change beyond
    /// `maxChangePercent` either way fails. Without previous counts for a system it is skipped
    /// with a warning.
    ///
    /// The same-date rule first is what makes most holidays pass: bus service on Thanksgiving,
    /// Christmas and New Year's Day is 37 % under a normal Thursday or Friday, but the previous
    /// build (built days earlier) already had that same reduced schedule. The holiday profiles
    /// cover dates new to this build (a feed extended its calendar).
    public static func tripCounts(current: [String: [ServiceDate: Int]], previous: [String: [ServiceDate: Int]]?,
                                  holidays: Set<ServiceDate>, maxChangePercent: Double,
                                  holidayProfiles: [GateConfiguration.Thresholds.TripCounts.HolidayProfile] = [.weekday, .saturday, .sunday])
        -> GateCheckResult {
        guard let previous else {
            return GateCheckResult(name: "tripCounts", status: .skipped, summary: "no previous build to compare with",
                                   warnings: ["no previous manifest or trip counts: trip counts not compared"])
        }
        var failures: [String] = [], warnings: [String] = [], notes: [String] = [], metrics: [String: Double] = [:]
        var compared = 0
        for (system, counts) in current.sorted(by: { $0.key < $1.key }) {
            guard let before = previous[system], !before.isEmpty else {
                warnings.append("\(system): no previous trip counts; not compared")
                continue
            }
            var byWeekday: [Weekday: [Int]] = [:]
            for (date, trips) in before where !holidays.contains(date) { byWeekday[date.weekday, default: []].append(trips) }
            let medians = byWeekday.mapValues(median)
            var sameDate = 0, profile = 0, worst: (delta: Double, line: String)?
            for (date, trips) in counts.sorted(by: { $0.key < $1.key }) {
                let reference: Double, basis: String
                if let same = before[date] {
                    reference = Double(same)
                    basis = "the previous build's same date"
                    sameDate += 1
                } else if holidays.contains(date) {
                    let candidates = holidayProfiles.compactMap { kind -> (Double, String)? in
                        let day: Weekday = switch kind { case .weekday: date.weekday; case .saturday: .saturday; case .sunday: .sunday }
                        return medians[day].map { ($0, "the previous build's median \(day) (holiday, nearest profile)") }
                    }
                    guard let nearest = candidates.min(by: { abs(Double(trips) - $0.0) < abs(Double(trips) - $1.0) }) else {
                        warnings.append("\(system) \(SetSystems.isoDay(date)): no previous day of a holiday profile")
                        continue
                    }
                    (reference, basis) = nearest
                    profile += 1
                } else {
                    guard let usual = medians[date.weekday] else {
                        warnings.append("\(system) \(SetSystems.isoDay(date)): no previous \(date.weekday)s")
                        continue
                    }
                    reference = usual
                    basis = "the previous build's median \(date.weekday)"
                    profile += 1
                }
                compared += 1
                guard reference > 0 else {
                    if trips > 0 { notes.append("\(system) \(SetSystems.isoDay(date)): \(trips) trips where \(basis) had none") }
                    continue
                }
                let delta = (Double(trips) - reference) / reference
                let line = String(format: "%@ %@: %d trips vs %.0f (%@), %+.1f%%", system, SetSystems.isoDay(date), trips, reference, basis, delta * 100)
                if worst == nil || abs(delta) > abs(worst!.delta) { worst = (delta, line) }
                if abs(delta) * 100 > maxChangePercent { failures.append(line) }
            }
            metrics["\(system).sameDate"] = Double(sameDate)
            metrics["\(system).weekdayProfile"] = Double(profile)
            if let worst {
                metrics["\(system).worstChangePercent"] = (worst.delta * 1000).rounded() / 10
                notes.append("worst: \(worst.line)")
            }
        }
        return .verdict("tripCounts", checked: compared > 0,
                        summary: failures.isEmpty ? "\(compared) dates within ±\(Int(maxChangePercent))% of the previous build"
                                                  : "\(failures.count) of \(compared) dates beyond ±\(Int(maxChangePercent))%",
                        failures: failures, warnings: warnings, notes: notes, metrics: metrics)
    }

    static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? Double(sorted[middle]) : Double(sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: Streets

    /// Each service-area region keeps at least its threshold share of street length through the
    /// component filter (`stats.regions` in `reports/streets.json`). Every configured region must be
    /// present; a region without its own threshold uses the default.
    public static func streetRegions(_ regions: [String: StreetBuildStats.RegionLength],
                                     thresholds: GateConfiguration.Thresholds.Streets) -> GateCheckResult {
        var failures: [String] = [], notes: [String] = [], metrics: [String: Double] = [:]
        for name in thresholds.regions.keys.sorted() where regions[name] == nil {
            failures.append("\(name): not in the streets report's regions")
        }
        for (name, region) in regions.sorted(by: { $0.key < $1.key }) {
            let minimum = thresholds.regions[name] ?? thresholds.minKeptSharePercent
            let percent = region.keptShare * 100
            metrics["\(name).keptSharePercent"] = (percent * 100).rounded() / 100
            let line = String(format: "%@: %.2f%% of %.1f km kept (minimum %.0f%%)", name, percent, region.totalMeters / 1000, minimum)
            notes.append(line)
            if percent < minimum { failures.append(line) }
        }
        return .verdict("streets", checked: !regions.isEmpty,
                        summary: failures.isEmpty ? "\(regions.count) regions keep their street share" : "\(failures.count) region(s) under their street share",
                        failures: failures, notes: notes, metrics: metrics)
    }

    // MARK: Snapping

    /// A routable stop as the snapping check sees it.
    public struct SnapStop: Sendable, Equatable {
        /// `B:203592`.
        public var id: String
        public var name: String
        public var inServiceArea: Bool
        public var streetEntry: Bool
        public var streetExit: Bool
        /// The farthest of its access points from its street snap; 0 without access points.
        public var maxSnapMeters: Double

        public init(id: String, name: String, inServiceArea: Bool, streetEntry: Bool, streetExit: Bool, maxSnapMeters: Double) {
            self.id = id
            self.name = name
            self.inServiceArea = inServiceArea
            self.streetEntry = streetEntry
            self.streetExit = streetExit
            self.maxSnapMeters = maxSnapMeters
        }
    }

    /// Every routable stop inside the service area can be entered and left from the street, and
    /// every one of its access points snaps within `maxSnapMeters`, except as the allowlist says.
    /// Stops outside the service area are only counted. Allowlist entries that no longer match
    /// anything are warnings, so the list does not rot.
    public static func snapping(_ stops: [SnapStop], maxSnapMeters: Double, exceptions: [GateConfiguration.SnapException]) -> GateCheckResult {
        var used = Set<Int>()
        func exception(_ stop: String, _ rule: GateConfiguration.SnapException.Rule) -> (Int, GateConfiguration.SnapException)? {
            guard let index = exceptions.firstIndex(where: { $0.stop == stop && $0.rule == rule }) else { return nil }
            return (index, exceptions[index])
        }
        var failures: [String] = [], notes: [String] = []
        var inside = 0, outside = 0, worst = 0.0
        for stop in stops.sorted(by: { $0.id < $1.id }) {
            guard stop.inServiceArea else { outside += 1; continue }
            inside += 1
            if !stop.streetEntry || !stop.streetExit {
                let missing = [stop.streetEntry ? nil : "entry", stop.streetExit ? nil : "exit"].compactMap { $0 }.joined(separator: " and ")
                if let (index, allowed) = exception(stop.id, .noStreetAccess) {
                    used.insert(index)
                    notes.append("allowlisted: \(stop.id) \(stop.name): no street \(missing) (\(allowed.reason))")
                } else {
                    failures.append("\(stop.id) \(stop.name): routable inside the service area with no street \(missing)")
                }
            }
            if stop.maxSnapMeters > maxSnapMeters {
                if let (index, allowed) = exception(stop.id, .snap), stop.maxSnapMeters <= allowed.maxMeters ?? maxSnapMeters {
                    used.insert(index)
                    notes.append(String(format: "allowlisted: %@ %@: snaps at %.1f m (allowed %.0f m: %@)", stop.id, stop.name, stop.maxSnapMeters,
                                        allowed.maxMeters ?? maxSnapMeters, allowed.reason))
                } else {
                    failures.append(String(format: "%@ %@: an access point snaps at %.1f m, over %.0f m", stop.id, stop.name, stop.maxSnapMeters, maxSnapMeters))
                }
            } else {
                worst = max(worst, stop.maxSnapMeters)
            }
        }
        let warnings = exceptions.indices.filter { !used.contains($0) }.map {
            "allowlist entry \(exceptions[$0].stop) (\(exceptions[$0].rule.rawValue)) matched nothing; remove it if the stop is fixed or gone"
        }
        return .verdict("snapping", checked: inside > 0,
                        summary: failures.isEmpty ? "\(inside) routable stops in the service area reach the street within \(Int(maxSnapMeters)) m"
                                                  : "\(failures.count) routable stop(s) fail street access or snapping",
                        failures: failures, warnings: warnings, notes: notes,
                        metrics: ["stopsInServiceArea": Double(inside), "stopsOutside": Double(outside), "maxSnapMetersWithinLimit": worst,
                                  "allowlisted": Double(used.count)])
    }
}
