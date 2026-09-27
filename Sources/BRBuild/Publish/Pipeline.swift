import Foundation

/// One step of `bikeride-data all`. `allCases` is the only valid order: config is built before
/// links (links bakes config values and names config in `builtAgainst`) and after the `tt-*` and
/// `stations` its reference checks read; flows depends on nothing (its `builtAgainst` is empty);
/// the gate runs before the manifest, and the heartbeat is written last.
public enum PipelineStep: String, CaseIterable, Sendable, Comparable {
    case streets, timetables, stations, config, links, flows, gate, manifest, heartbeat

    public static func < (a: PipelineStep, b: PipelineStep) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// Whether the step builds an artifact (the others publish the set).
    public var buildsArtifact: Bool {
        switch self {
        case .streets, .timetables, .stations, .config, .links, .flows: true
        case .gate, .manifest, .heartbeat: false
        }
    }
}

/// What `bikeride-data all` does with each step's exit status, and which steps it runs. The CLI
/// supplies the step bodies (the step commands); the tests drive the same policy with the library
/// compilers.
public enum Pipeline {
    /// What a step's exit status means for the run.
    public enum Decision: Equatable, Sendable {
        case proceed
        /// Go on; the text is repeated at the end of the run.
        case proceedWithWarning(String)
        /// End the run with this exit status: nothing after the step runs.
        case stop(Int32)
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The steps named in `--skip` (comma-separated, any case, blanks ignored).
    public static func steps(named list: String) throws -> Set<PipelineStep> {
        var steps = Set<PipelineStep>()
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !name.isEmpty {
            guard let step = PipelineStep(rawValue: name) else {
                throw UsageError(description: "unknown step '\(name)' (steps: \(PipelineStep.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            steps.insert(step)
        }
        return steps
    }

    /// The steps a run skips: those asked for, plus those that cannot run given them.
    /// - Without `.xz` blobs (`--no-xz`) there is nothing to publish: gate, manifest and heartbeat
    ///   are skipped (the gate's xz check would fail every time).
    /// - The heartbeat names the manifest this run writes: skipping the manifest skips it.
    public static func effectiveSkips(_ requested: Set<PipelineStep>, compress: Bool) -> (skip: Set<PipelineStep>, notes: [String]) {
        var skip = requested, notes: [String] = []
        if !compress {
            let implied = [PipelineStep.gate, .manifest, .heartbeat].filter { !skip.contains($0) }
            if !implied.isEmpty {
                notes.append("--no-xz: no blobs to publish, so \(implied.map(\.rawValue).joined(separator: ", ")) skipped")
                skip.formUnion(implied)
            }
        }
        if skip.contains(.manifest), !skip.contains(.heartbeat) {
            notes.append("manifest skipped, so heartbeat skipped (it names the manifest this run writes)")
            skip.insert(.heartbeat)
        }
        return (skip, notes)
    }

    /// The policy, per step:
    /// - `streets`: 2 (a sanity route failed) is a warning; the artifact is written and the gate
    ///   checks the set.
    /// - `timetables`, `stations`, `links`: any failure stops the run.
    /// - `config`: 3 (a reference check failed: no config.bin) and every other failure stop the
    ///   run; links cannot be built without it.
    /// - `flows`: 4 (nothing new, or offline without trip data) and 3 (its own gate failed) keep
    ///   the flows.bin in place, if any, and its report, and go on: the set gate's `flows` check
    ///   decides whether that file may be published (flows is optional unless required). 1 (an
    ///   error: a download, GBFS, the holiday calendar; flows writes nothing then) is a warning too,
    ///   unless flows is required (`requireFlows`): then it stops the run. Any other status stops.
    /// - `gate`: 3 (a hard failure) stops with 3: no manifest, no heartbeat, the previous set stays
    ///   current. Any other failure stops too.
    /// - `manifest`, `heartbeat`: any failure stops the run.
    public static func decision(_ step: PipelineStep, status: Int32, requireFlows: Bool = false) -> Decision {
        guard status != 0 else { return .proceed }
        switch step {
        case .streets:
            return status == 2 ? .proceedWithWarning("streets: sanity routes failed (see reports/streets.json)") : .stop(status)
        case .timetables, .stations, .links:
            return .stop(status)
        case .config:
            return .stop(status)
        case .flows:
            switch status {
            case 3: return .proceedWithWarning("flows: its gate failed (see reports/flows-failed.json); the flows.bin in place (if any) and its report are kept, and the set gate decides whether it is published")
            case 4: return .proceedWithWarning("flows: nothing new, or no trip data offline; the flows.bin in place (if any) is kept")
            case 1 where !requireFlows: return .proceedWithWarning("flows: failed with an error (above); the flows.bin in place (if any) is kept, and the set gate decides whether it is published")
            default: return .stop(status)
            }
        case .gate:
            return .stop(status)
        case .manifest, .heartbeat:
            return .stop(status)
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// The run's exit status: 0, or the status of the step it stopped at.
        public var status: Int32
        /// Each step run, with its exit status, in order.
        public var ran: [(step: PipelineStep, status: Int32)]
        public var warnings: [String]
        public var stoppedAt: PipelineStep?

        public static func == (a: Outcome, b: Outcome) -> Bool {
            a.status == b.status && a.warnings == b.warnings && a.stoppedAt == b.stoppedAt
                && a.ran.map(\.step) == b.ran.map(\.step) && a.ran.map(\.status) == b.ran.map(\.status)
        }
    }

    /// Runs `body` for every step not in `skip`, in order, and applies ``decision(_:status:requireFlows:)``.
    public static func run(skip: Set<PipelineStep>, requireFlows: Bool = false, log: (String) -> Void = { _ in },
                           _ body: (PipelineStep) throws -> Int32) rethrows -> Outcome {
        var outcome = Outcome(status: 0, ran: [], warnings: [], stoppedAt: nil)
        for step in PipelineStep.allCases {
            guard !skip.contains(step) else {
                log("\(step.rawValue): skipped")
                continue
            }
            let status = try body(step)
            outcome.ran.append((step, status))
            switch decision(step, status: status, requireFlows: requireFlows) {
            case .proceed:
                break
            case .proceedWithWarning(let warning):
                log("warning: \(warning)")
                outcome.warnings.append(warning)
            case .stop(let exit):
                log("stopping: \(step.rawValue) exited \(status)" + (step == .gate && status == 3 ? " (hard failure: no manifest, no heartbeat)" : ""))
                outcome.status = exit
                outcome.stoppedAt = step
                return outcome
            }
        }
        return outcome
    }
}

extension Pipeline {
    /// The documents a published set adds to its data directory, in the order they are written.
    public static let publishedFileNames = [TripCountSidecar.fileName, SetManifest.fileName, SetHeartbeat.fileName]

    /// Where ``retirePublished(in:previous:)`` moves them: `<out>/../work/published-before/`.
    public static func retiredDirectory(for out: URL) -> URL {
        out.deletingLastPathComponent().appendingPathComponent("work/published-before", isDirectory: true)
    }

    /// What ``retirePublished(in:previous:)`` did, and the previous-set inputs the run uses.
    public struct Retired: Equatable, Sendable {
        /// The documents moved out of the data directory (names), now in ``directory``.
        public var moved: [String]
        public var directory: URL
        /// `--previous`: moved into ``directory`` with the others when it was the data directory's
        /// own manifest.json.
        public var previous: URL?
        /// The heartbeat the run's heartbeat carries `lastTimetableSuccessAt` over from (when this
        /// run did not build the timetables): the one beside ``previous``; without `--previous`,
        /// the data directory's last one (in ``directory``), if any.
        public var previousHeartbeat: URL?

        public init(moved: [String], directory: URL, previous: URL?, previousHeartbeat: URL?) {
            self.moved = moved
            self.directory = directory
            self.previous = previous
            self.previousHeartbeat = previousHeartbeat
        }
    }

    /// Before a run that runs any step: moves `manifest.json`, `trip-counts.json` and
    /// `heartbeat.json` out of the data directory, into ``retiredDirectory(for:)`` (replacing what
    /// is there). They describe the set that was there; once a step rewrites an artifact they
    /// describe nothing, and a run that stops (a gate hard failure, a config failure) must leave
    /// no published documents beside files they do not describe. A run that publishes writes new
    /// ones. `previous` may be `<out>/manifest.json` (the set in place is the previous set): it is
    /// moved with the others and the result points at the moved copy. Any other file in the data
    /// directory cannot be `--previous` (its sidecar would be moved from under it), nor can a
    /// file in the retired directory when there are documents to move (they replace it).
    public static func retirePublished(in out: URL, previous: URL?) throws -> Retired {
        let out = out.standardizedFileURL, directory = retiredDirectory(for: out)
        var previous = previous?.standardizedFileURL
        func isIn(_ folder: URL) -> Bool {
            previous.map { $0.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path } ?? false
        }
        let inOut = isIn(out)
        if let url = previous, inOut, url.lastPathComponent != SetManifest.fileName {
            throw UsageError(description: "--previous \(url.path) is in the data directory but is not its \(SetManifest.fileName) "
                + "(all moves the published documents there out of the way before it builds); copy it elsewhere")
        }
        let fileManager = FileManager.default
        let present = publishedFileNames.filter { fileManager.fileExists(atPath: out.appendingPathComponent($0).path) }
        if let url = previous, isIn(directory), !present.isEmpty {
            throw UsageError(description: "--previous \(url.path) is in \(directory.path), which all replaces with the data directory's "
                + "published documents; pass \(out.appendingPathComponent(SetManifest.fileName).path) or a copy elsewhere")
        }
        if !present.isEmpty {
            if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in present {
                try fileManager.moveItem(at: out.appendingPathComponent(name), to: directory.appendingPathComponent(name))
            }
        }
        if inOut { previous = directory.appendingPathComponent(SetManifest.fileName) }
        let retiredHeartbeat = directory.appendingPathComponent(SetHeartbeat.fileName)
        let heartbeat = previous.map { $0.deletingLastPathComponent().appendingPathComponent(SetHeartbeat.fileName) }
            ?? (fileManager.fileExists(atPath: retiredHeartbeat.path) ? retiredHeartbeat : nil)
        return Retired(moved: present, directory: directory, previous: previous, previousHeartbeat: heartbeat)
    }
}
