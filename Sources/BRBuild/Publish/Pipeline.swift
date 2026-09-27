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
    ///   the flows.bin in place, if any, and go on: the set gate's `flows` check decides whether
    ///   that file may be published (flows is optional unless required). Any other failure stops.
    /// - `gate`: 3 (a hard failure) stops with 3: no manifest, no heartbeat, the previous set stays
    ///   current. Any other failure stops too.
    /// - `manifest`, `heartbeat`: any failure stops the run.
    public static func decision(_ step: PipelineStep, status: Int32) -> Decision {
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
            case 3: return .proceedWithWarning("flows: its gate failed; the flows.bin in place (if any) is kept, and the set gate decides whether it is published (see reports/flows.json)")
            case 4: return .proceedWithWarning("flows: nothing new, or no trip data offline; the flows.bin in place (if any) is kept")
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

    /// Runs `body` for every step not in `skip`, in order, and applies ``decision(_:status:)``.
    public static func run(skip: Set<PipelineStep>, log: (String) -> Void = { _ in },
                           _ body: (PipelineStep) throws -> Int32) rethrows -> Outcome {
        var outcome = Outcome(status: 0, ran: [], warnings: [], stoppedAt: nil)
        for step in PipelineStep.allCases {
            guard !skip.contains(step) else {
                log("\(step.rawValue): skipped")
                continue
            }
            let status = try body(step)
            outcome.ran.append((step, status))
            switch decision(step, status: status) {
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
