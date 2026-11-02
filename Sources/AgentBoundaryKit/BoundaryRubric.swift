/// Thresholds for the rubric. The defaults are starting points, not truths;
/// a team should set them from its own evals.
public struct RubricThresholds: Sendable, Hashable {
    /// Context the main loop can carry before quality measurably drops.
    public var contextBudgetTokens: Int
    /// Tool definitions the main loop can see before tool choice degrades.
    /// Anthropic's guidance puts the cliff somewhere between 30 and 50.
    public var toolBudget: Int
    /// Share of an agent's calls that must be parallel fan-out to justify a boundary.
    public var minParallelShare: Double
    /// Share of tasks where A is immediately followed by B that makes them a merge pair.
    public var minPairShare: Double

    public init(contextBudgetTokens: Int = 120_000, toolBudget: Int = 40, minParallelShare: Double = 0.5, minPairShare: Double = 0.25) {
        self.contextBudgetTokens = contextBudgetTokens
        self.toolBudget = toolBudget
        self.minParallelShare = minParallelShare
        self.minPairShare = minPairShare
    }

    public static let standard = RubricThresholds()
}

/// Why a boundary earns its coordination cost.
public enum KeepReason: Sendable, Hashable, CustomStringConvertible {
    /// It holds the conversation with the user, so a full handoff is real.
    case ownsConversation
    /// Most calls are parallel fan-out in fresh, discardable contexts.
    case parallelFanOut(share: Double)
    /// Folding its working set into the main loop would blow the context budget.
    case contextBloat(foldedTokens: Int, budget: Int)
    /// Folding its tools would push the main loop past the tool budget.
    case toolSelection(foldedTools: Int, budget: Int)
    /// Its prompt contradicts the main prompt on these keys.
    case conflictingInstructions(keys: [String])

    public var description: String {
        switch self {
        case .ownsConversation:
            return "Talks to the user directly"
        case .parallelFanOut(let share):
            return "Parallel fan-out on \(percent(share)) of calls"
        case .contextBloat(let folded, let budget):
            return "Folded context \(thousands(folded)) > budget \(thousands(budget))"
        case .toolSelection(let folded, let budget):
            return "Folded tools \(folded) > budget \(budget)"
        case .conflictingInstructions(let keys):
            return "Prompt conflicts with main on: \(keys.joined(separator: ", "))"
        }
    }

    /// Conflicts are fixable in an afternoon; the other reasons are structural.
    public var isFixable: Bool {
        if case .conflictingInstructions = self { return true }
        return false
    }
}

public enum Verdict: Sendable, Hashable {
    /// Fold into the main loop as a skill plus tools.
    case fold
    /// Fold together with a tightly coupled partner, as one step.
    case foldWith(partner: String, pairShare: Double)
    /// Keep the boundary, for at least one of these reasons.
    case keep([KeepReason])

    public var isFold: Bool {
        if case .keep = self { return false }
        return true
    }
}

/// The rubric's answer for one subagent, with the numbers behind it.
public struct BoundaryAssessment: Sendable, Hashable, Identifiable {
    public var id: String { agent }
    public let agent: String
    public let role: AgentRole
    public let verdict: Verdict
    public let callShare: Double
    public let parallelShare: Double
    /// Raw tokens read per token handed back. High means the coordinator only
    /// ever sees a thin summary of what the subagent saw.
    public let compressionRatio: Double
    public let strongestPartner: AgentPair?
    public let strongestPairShare: Double
    public let partnerEntityOverlap: Double

    /// True when the only thing keeping the boundary is fixable.
    public var foldsAfterFix: Bool {
        guard case .keep(let reasons) = verdict, !reasons.isEmpty else { return false }
        return reasons.allSatisfy(\.isFixable)
    }
}

/// Scores each subagent the way a lead scores a module boundary: a boundary is
/// worth its coordination cost only when it buys isolation (context), parallelism,
/// or a real owner of the conversation.
public struct BoundaryRubric: Sendable {
    public let thresholds: RubricThresholds

    public init(thresholds: RubricThresholds = .standard) {
        self.thresholds = thresholds
    }

    public func assess(topology: Topology, traces: [TaskTrace]) -> [BoundaryAssessment] {
        let stats = TraceStats(traces: traces, topology: topology)
        let mainTools = Set(topology.mainTools)

        // Pass 1: keep reasons per agent, judged one at a time against the main loop.
        var reasons: [String: [KeepReason]] = [:]
        for agent in topology.subagents {
            var why: [KeepReason] = []
            if agent.talksToUser { why.append(.ownsConversation) }
            let parallel = stats.parallelShare[agent.id] ?? 0
            if parallel >= thresholds.minParallelShare { why.append(.parallelFanOut(share: parallel)) }
            let folded = topology.mainContextTokens + agent.workingSetTokens
            if folded > thresholds.contextBudgetTokens {
                why.append(.contextBloat(foldedTokens: folded, budget: thresholds.contextBudgetTokens))
            }
            let toolCount = mainTools.union(agent.tools).count
            if toolCount > thresholds.toolBudget {
                why.append(.toolSelection(foldedTools: toolCount, budget: thresholds.toolBudget))
            }
            let conflicts = agent.rules.keys
                .filter { key in topology.mainRules[key].map { $0 != agent.rules[key] } ?? false }
                .sorted()
            if !conflicts.isEmpty { why.append(.conflictingInstructions(keys: conflicts)) }
            reasons[agent.id] = why
        }

        // Pass 2: verdicts. A fold candidate merges with its strongest partner
        // only if that partner is also a fold candidate.
        return topology.subagents.map { agent in
            let partner = strongestPartner(of: agent.id, in: stats)
            let other = partner.map { $0.pair.from == agent.id ? $0.pair.to : $0.pair.from }
            let why = reasons[agent.id] ?? []
            let verdict: Verdict
            if !why.isEmpty {
                verdict = .keep(why)
            } else if let partner, let other, partner.share >= thresholds.minPairShare,
                      let otherReasons = reasons[other], otherReasons.isEmpty {
                verdict = .foldWith(partner: other, pairShare: partner.share)
            } else {
                verdict = .fold
            }
            let handoff = stats.meanHandoffOut[agent.id] ?? 0
            return BoundaryAssessment(
                agent: agent.id,
                role: agent.role,
                verdict: verdict,
                callShare: stats.callShare[agent.id] ?? 0,
                parallelShare: stats.parallelShare[agent.id] ?? 0,
                compressionRatio: handoff > 0 ? Double(agent.workingSetTokens) / handoff : 0,
                strongestPartner: partner?.pair,
                strongestPairShare: partner?.share ?? 0,
                partnerEntityOverlap: other.map { stats.entityOverlap(agent.id, $0) } ?? 0
            )
        }
    }

    private func strongestPartner(of agent: String, in stats: TraceStats) -> (pair: AgentPair, share: Double)? {
        stats.pairShare
            .filter { $0.key.from == agent || $0.key.to == agent }
            .filter { $0.key.from != $0.key.to }
            .max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }
            .map { ($0.key, $0.value) }
    }
}

func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func thousands(_ value: Int) -> String {
    value >= 1_000 ? "\(Int((Double(value) / 1_000).rounded()))k" : "\(value)"
}
