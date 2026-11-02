/// One step of a migration: fold these agents into the main loop together,
/// then run the eval gate before taking the next step.
public struct FoldStep: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let agents: [String]
    /// Main-loop context and tool count after this step.
    public let contextAfter: Int
    public let toolsAfter: Int
    /// Production chains touching these agents. The eval must have a task for each.
    public let chainsToCover: [AgentPair]
}

public struct FoldPlan: Sendable, Hashable {
    public let steps: [FoldStep]
    /// Fold candidates that would push the loop past a budget if folded on top
    /// of the earlier steps. Revisit them after tool search or skill trimming.
    public let deferred: [String]
    /// Boundaries the rubric keeps.
    public let kept: [String]

    /// Orders fold candidates the way Anthropic's guidance suggests: most-used
    /// first, coupled pairs as one step, and budgets checked cumulatively,
    /// because the per-agent check in the rubric can't see the sum.
    public static func make(
        topology: Topology,
        traces: [TaskTrace],
        assessments: [BoundaryAssessment],
        thresholds: RubricThresholds = .standard,
        minChainShare: Double = 0.1
    ) -> FoldPlan {
        let stats = TraceStats(traces: traces, topology: topology)
        let chains = stats.chains(minShare: minChainShare)
        let byID = Dictionary(uniqueKeysWithValues: assessments.map { ($0.agent, $0) })

        let candidates = assessments
            .filter(\.verdict.isFold)
            .sorted { $0.callShare != $1.callShare ? $0.callShare > $1.callShare : $0.agent < $1.agent }

        var context = topology.mainContextTokens
        var tools = Set(topology.mainTools)
        var placed = Set<String>()
        var steps: [FoldStep] = []
        var deferred: [String] = []

        for candidate in candidates where !placed.contains(candidate.agent) {
            var group = [candidate.agent]
            // Group only a mutual pair: the partner's verdict must name this agent back.
            if case .foldWith(let partner, _) = candidate.verdict, !placed.contains(partner),
               case .foldWith(let back, _)? = byID[partner]?.verdict, back == candidate.agent {
                group.append(partner)
            }
            let specs = group.compactMap { topology.agent($0) }
            let nextContext = context + specs.reduce(0) { $0 + $1.workingSetTokens }
            let nextTools = specs.reduce(tools) { $0.union($1.tools) }
            placed.formUnion(group)

            if nextContext > thresholds.contextBudgetTokens || nextTools.count > thresholds.toolBudget {
                deferred.append(contentsOf: group)
                continue
            }
            context = nextContext
            tools = nextTools
            let members = Set(group)
            steps.append(FoldStep(
                index: steps.count + 1,
                agents: group,
                contextAfter: context,
                toolsAfter: tools.count,
                chainsToCover: chains.filter { members.contains($0.from) || members.contains($0.to) }
            ))
        }

        let kept = assessments.filter { !$0.verdict.isFold }.map(\.agent)
        return FoldPlan(steps: steps, deferred: deferred, kept: kept)
    }
}
