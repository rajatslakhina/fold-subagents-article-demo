/// An ordered pair of specialists where `to` ran immediately after `from`.
public struct AgentPair: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let from: String
    public let to: String

    public init(_ from: String, _ to: String) {
        self.from = from
        self.to = to
    }

    public var description: String { "\(from) → \(to)" }

    public static func < (lhs: AgentPair, rhs: AgentPair) -> Bool {
        (lhs.from, lhs.to) < (rhs.from, rhs.to)
    }
}

/// Usage numbers computed from production traces. Routers and planners are
/// left out of pair counts: every task starts with the router, so pairing it
/// with whatever comes next says nothing about coupling between specialists.
public struct TraceStats: Sendable {
    public let taskCount: Int
    /// Share of tasks that called the agent at least once.
    public let callShare: [String: Double]
    /// Share of the agent's calls that ran in a parallel group of 2 or more.
    public let parallelShare: [String: Double]
    /// Share of tasks containing `from` immediately followed by `to`.
    public let pairShare: [AgentPair: Double]
    /// Every entity the agent touched across all traces.
    public let entities: [String: Set<String>]
    /// Mean tokens the agent handed back per call.
    public let meanHandoffOut: [String: Double]

    public init(traces: [TaskTrace], topology: Topology) {
        let coordinatorRoles: Set<AgentRole> = [.router, .planner]
        let skipInPairs = Set(topology.subagents.filter { coordinatorRoles.contains($0.role) }.map(\.id))

        var tasksCalling: [String: Int] = [:]
        var calls: [String: Int] = [:]
        var parallelCalls: [String: Int] = [:]
        var pairTasks: [AgentPair: Int] = [:]
        var touched: [String: Set<String>] = [:]
        var handoffSum: [String: Int] = [:]

        for trace in traces {
            var groupSizes: [Int: Int] = [:]
            for call in trace.invocations {
                if let group = call.parallelGroup { groupSizes[group, default: 0] += 1 }
            }
            for name in Set(trace.invocations.map(\.agent)) {
                tasksCalling[name, default: 0] += 1
            }
            for call in trace.invocations {
                calls[call.agent, default: 0] += 1
                handoffSum[call.agent, default: 0] += call.handoffOutTokens
                touched[call.agent, default: []].formUnion(call.entities)
                if let group = call.parallelGroup, (groupSizes[group] ?? 0) >= 2 {
                    parallelCalls[call.agent, default: 0] += 1
                }
            }

            // Collapse consecutive calls to the same agent (a parallel fan-out
            // is one step), drop coordinators, then count adjacent pairs once per task.
            var steps: [String] = []
            for call in trace.invocations where !skipInPairs.contains(call.agent) {
                if steps.last != call.agent { steps.append(call.agent) }
            }
            var seen = Set<AgentPair>()
            if steps.count >= 2 {
                for index in 1..<steps.count {
                    seen.insert(AgentPair(steps[index - 1], steps[index]))
                }
            }
            for pair in seen { pairTasks[pair, default: 0] += 1 }
        }

        let total = traces.count
        let denominator = Double(max(total, 1))
        taskCount = total
        callShare = tasksCalling.mapValues { Double($0) / denominator }
        pairShare = pairTasks.mapValues { Double($0) / denominator }
        entities = touched
        var parallel: [String: Double] = [:]
        var handoff: [String: Double] = [:]
        for (name, count) in calls where count > 0 {
            parallel[name] = Double(parallelCalls[name] ?? 0) / Double(count)
            handoff[name] = Double(handoffSum[name] ?? 0) / Double(count)
        }
        parallelShare = parallel
        meanHandoffOut = handoff
    }

    /// Pairs at or above a share of tasks, most frequent first.
    public func chains(minShare: Double) -> [AgentPair] {
        pairShare
            .filter { $0.value >= minShare }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// Jaccard overlap of the data two agents touch, 0...1.
    public func entityOverlap(_ a: String, _ b: String) -> Double {
        let left = entities[a] ?? []
        let right = entities[b] ?? []
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }
}
