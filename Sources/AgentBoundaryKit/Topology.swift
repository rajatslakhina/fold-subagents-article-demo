/// What an agent is for. Routers and planners are the parts of a multi-agent
/// harness that a capable model now does inside its own loop.
public enum AgentRole: String, Sendable, Hashable, CaseIterable {
    case router
    case planner
    case specialist
}

/// One subagent as it exists in production today.
public struct AgentSpec: Sendable, Hashable, Identifiable {
    public let id: String
    public let role: AgentRole
    /// The team that owns its prompt and evals.
    public let owner: String
    public let tools: [String]
    /// Average raw context the agent reads per call (logs, files, records),
    /// before it summarises anything back to the coordinator.
    public let workingSetTokens: Int
    /// Instruction keys in its prompt and the value each one sets,
    /// e.g. `"tone": "formal"`. Used to find conflicts with the main prompt.
    public let rules: [String: String]
    /// True when the agent holds the conversation with the user directly.
    public let talksToUser: Bool

    public init(
        id: String,
        role: AgentRole = .specialist,
        owner: String,
        tools: [String] = [],
        workingSetTokens: Int,
        rules: [String: String] = [:],
        talksToUser: Bool = false
    ) {
        self.id = id
        self.role = role
        self.owner = owner
        self.tools = tools
        self.workingSetTokens = max(0, workingSetTokens)
        self.rules = rules
        self.talksToUser = talksToUser
    }
}

/// The coordinator (main loop) plus the subagents it calls.
public struct Topology: Sendable, Hashable {
    public let mainTools: [String]
    public let mainRules: [String: String]
    /// Tokens the main loop already carries: system prompt, skill and tool
    /// descriptions, and the conversation it typically holds.
    public let mainContextTokens: Int
    public let subagents: [AgentSpec]

    public init(mainTools: [String], mainRules: [String: String], mainContextTokens: Int, subagents: [AgentSpec]) {
        self.mainTools = mainTools
        self.mainRules = mainRules
        self.mainContextTokens = max(0, mainContextTokens)
        self.subagents = subagents
    }

    public func agent(_ id: String) -> AgentSpec? {
        subagents.first { $0.id == id }
    }
}

/// One subagent call inside a production task.
public struct Invocation: Sendable, Hashable {
    public let agent: String
    /// Calls that share a group id ran concurrently, each in a fresh context
    /// that was thrown away afterwards. `nil` means it ran on its own.
    public let parallelGroup: Int?
    /// Data the call touched: tickets, crash reports, string catalogs…
    public let entities: Set<String>
    /// Tokens the subagent handed back to the coordinator.
    public let handoffOutTokens: Int

    public init(agent: String, parallelGroup: Int? = nil, entities: Set<String> = [], handoffOutTokens: Int) {
        self.agent = agent
        self.parallelGroup = parallelGroup
        self.entities = entities
        self.handoffOutTokens = max(0, handoffOutTokens)
    }
}

/// The ordered subagent calls for one task, as recorded in production.
public struct TaskTrace: Sendable, Hashable, Identifiable {
    public let id: String
    public let invocations: [Invocation]

    public init(id: String, invocations: [Invocation]) {
        self.id = id
        self.invocations = invocations
    }
}
