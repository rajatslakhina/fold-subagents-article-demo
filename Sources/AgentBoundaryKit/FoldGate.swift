public enum Variant: String, Sendable, Hashable, CaseIterable {
    case baseline
    case folded
}

/// A golden task in the shared end-to-end eval.
public struct EvalTask: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// Production chains this task exercises, e.g. `[["Changelog", "Notes"]]`.
    public let covers: [[String]]
    /// True for "the agent must never…" rules.
    public let isRule: Bool

    public init(id: String, title: String, covers: [[String]] = [], isRule: Bool = false) {
        self.id = id
        self.title = title
        self.covers = covers
        self.isRule = isRule
    }

    func covers(_ pair: AgentPair) -> Bool {
        covers.contains { chain in
            guard chain.count >= 2 else { return false }
            return zip(chain, chain.dropFirst()).contains { $0 == pair.from && $1 == pair.to }
        }
    }
}

public struct EvalResult: Sendable, Hashable {
    public let taskID: String
    public let variant: Variant
    public let run: Int
    public let passed: Bool

    public init(taskID: String, variant: Variant, run: Int, passed: Bool) {
        self.taskID = taskID
        self.variant = variant
        self.run = run
        self.passed = passed
    }
}

/// A task that passed every baseline run and failed at least one folded run.
public struct Flip: Sendable, Hashable, Identifiable {
    public var id: String { taskID }
    public let taskID: String
    public let title: String
    public let baselinePasses: Int
    public let baselineRuns: Int
    public let foldedPasses: Int
    public let foldedRuns: Int
}

public enum GateIssue: Sendable, Hashable, CustomStringConvertible {
    case flipped(Flip)
    case uncoveredChain(AgentPair)
    case tooFewRuns(taskID: String, variant: Variant, runs: Int)
    case missingResults(taskID: String, variant: Variant)

    public var description: String {
        switch self {
        case .flipped(let flip):
            return "\(flip.taskID) flipped: baseline \(flip.baselinePasses)/\(flip.baselineRuns), folded \(flip.foldedPasses)/\(flip.foldedRuns)"
        case .uncoveredChain(let pair):
            return "No eval task covers \(pair)"
        case .tooFewRuns(let task, let variant, let runs):
            return "\(task) has \(runs) \(variant.rawValue) run(s); need 2+"
        case .missingResults(let task, let variant):
            return "\(task) has no \(variant.rawValue) results"
        }
    }
}

/// Decides whether a fold step may ship. The mean pass rate is reported but
/// never decides: a fold that raises the mean and breaks one task is blocked.
public struct FoldGate: Sendable {
    public let tasks: [EvalTask]
    public let minRuns: Int

    public init(tasks: [EvalTask], minRuns: Int = 2) {
        self.tasks = tasks
        self.minRuns = max(1, minRuns)
    }

    public struct Report: Sendable, Hashable {
        public let baselinePassRate: Double
        public let foldedPassRate: Double
        public let flips: [Flip]
        public let issues: [GateIssue]

        public var canShip: Bool { issues.isEmpty }
        /// The trap: the score went up (or held) and something still broke.
        public var meanHidesRegression: Bool { foldedPassRate >= baselinePassRate && !flips.isEmpty }
    }

    public func evaluate(results: [EvalResult], productionChains: [AgentPair]) -> Report {
        var issues: [GateIssue] = []
        var flips: [Flip] = []

        for task in tasks {
            let base = results.filter { $0.taskID == task.id && $0.variant == .baseline }
            let fold = results.filter { $0.taskID == task.id && $0.variant == .folded }
            for (variant, rows) in [(Variant.baseline, base), (.folded, fold)] {
                if rows.isEmpty {
                    issues.append(.missingResults(taskID: task.id, variant: variant))
                } else if Set(rows.map(\.run)).count < minRuns {
                    issues.append(.tooFewRuns(taskID: task.id, variant: variant, runs: Set(rows.map(\.run)).count))
                }
            }
            let basePasses = base.filter(\.passed).count
            let foldPasses = fold.filter(\.passed).count
            if !base.isEmpty, basePasses == base.count, !fold.isEmpty, foldPasses < fold.count {
                let flip = Flip(taskID: task.id, title: task.title, baselinePasses: basePasses, baselineRuns: base.count, foldedPasses: foldPasses, foldedRuns: fold.count)
                flips.append(flip)
                issues.append(.flipped(flip))
            }
        }

        for chain in productionChains where !tasks.contains(where: { $0.covers(chain) }) {
            issues.append(.uncoveredChain(chain))
        }

        return Report(
            baselinePassRate: passRate(results, .baseline),
            foldedPassRate: passRate(results, .folded),
            flips: flips,
            issues: issues
        )
    }

    private func passRate(_ results: [EvalResult], _ variant: Variant) -> Double {
        let known = Set(tasks.map(\.id))
        let rows = results.filter { $0.variant == variant && known.contains($0.taskID) }
        guard !rows.isEmpty else { return 0 }
        return Double(rows.filter(\.passed).count) / Double(rows.count)
    }
}
