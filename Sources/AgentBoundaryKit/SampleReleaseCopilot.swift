/// A constructed example: an iOS team's release copilot with a router and six
/// specialists, each built by a different team. The traces and eval results
/// are synthetic. They are shaped like real ones so the rubric has something
/// honest to chew on, but they were not recorded from a production system.
public enum SampleReleaseCopilot {
    public static let topology = Topology(
        mainTools: ["search_tickets", "read_build", "post_comment", "fetch_testflight"],
        mainRules: ["tone": "friendly", "release_day": "tuesday"],
        mainContextTokens: 18_000,
        subagents: [
            AgentSpec(id: "IntentRouter", role: .router, owner: "Platform",
                      workingSetTokens: 2_000),
            AgentSpec(id: "ChangelogCollector", owner: "Release Eng",
                      tools: ["git_log", "jira_search"], workingSetTokens: 9_000),
            AgentSpec(id: "ReleaseNotesWriter", owner: "Product",
                      tools: ["draft_notes"], workingSetTokens: 6_000),
            AgentSpec(id: "MetadataChecker", owner: "Growth",
                      tools: ["asc_metadata_read", "screenshot_list"], workingSetTokens: 7_000),
            AgentSpec(id: "CrashTriage", owner: "Reliability",
                      tools: ["crash_query", "symbolicate", "dsym_fetch"], workingSetTokens: 140_000),
            AgentSpec(id: "LocalizationReviewer", owner: "Localization",
                      tools: ["string_catalog_read"], workingSetTokens: 30_000),
            AgentSpec(id: "ReviewReplyDrafter", owner: "Support",
                      tools: ["asc_reviews", "post_reply_draft"], workingSetTokens: 4_000,
                      rules: ["tone": "formal"]),
        ]
    )

    static let locales = ["de", "es", "fr", "it", "ja", "ko", "pt-BR", "zh-Hans"]

    /// 20 task traces in four shapes.
    public static let traces: [TaskTrace] = {
        func router() -> Invocation {
            Invocation(agent: "IntentRouter", entities: ["request"], handoffOutTokens: 60)
        }
        let changelog = Invocation(agent: "ChangelogCollector", entities: ["commits", "tickets"], handoffOutTokens: 800)
        let notes = Invocation(agent: "ReleaseNotesWriter", entities: ["commits", "tickets", "release"], handoffOutTokens: 500)
        let metadata = Invocation(agent: "MetadataChecker", entities: ["release", "screenshots"], handoffOutTokens: 300)
        let crash = Invocation(agent: "CrashTriage", entities: ["crashes", "dsyms", "release"], handoffOutTokens: 1_200)
        let reply = Invocation(agent: "ReviewReplyDrafter", entities: ["reviews"], handoffOutTokens: 400)
        let fanOut = locales.map { _ in
            Invocation(agent: "LocalizationReviewer", parallelGroup: 1, entities: ["strings"], handoffOutTokens: 250)
        }

        var traces: [TaskTrace] = []
        func add(_ prefix: String, _ count: Int, _ calls: [Invocation]) {
            for index in 1...count {
                traces.append(TaskTrace(id: "\(prefix)-\(index)", invocations: [router()] + calls))
            }
        }
        add("notes-and-metadata", 4, [changelog, notes, metadata])
        add("notes-only", 4, [changelog, notes])
        add("crash-fix-note", 2, [crash, notes])
        add("crash-triage", 2, [crash])
        add("localization-pass", 4, fanOut + [metadata])
        add("review-replies", 4, [reply])
        return traces
    }()

    /// Ten golden tasks: enough to start, per Anthropic's guidance.
    public static let evalTasks: [EvalTask] = [
        EvalTask(id: "G1", title: "Notes summarise every merged ticket", covers: [["ChangelogCollector", "ReleaseNotesWriter"]]),
        EvalTask(id: "G2", title: "Notes keep ticket IDs", covers: [["ChangelogCollector", "ReleaseNotesWriter", "MetadataChecker"]]),
        EvalTask(id: "G3", title: "What's New fits the 4,000-character limit", covers: [["MetadataChecker"]]),
        EvalTask(id: "G4", title: "Screenshot set complete for every device class", covers: [["MetadataChecker"]]),
        EvalTask(id: "G5", title: "Localized What's New matches the English notes", covers: [["LocalizationReviewer", "MetadataChecker"]]),
        EvalTask(id: "G6", title: "Review reply keeps the support tone", covers: [["ReviewReplyDrafter"]]),
        EvalTask(id: "G7", title: "Crash triage ranks the top three signatures", covers: [["CrashTriage"]]),
        EvalTask(id: "G8", title: "Never posts a reply without approval", covers: [["ReviewReplyDrafter"]], isRule: true),
        EvalTask(id: "G9", title: "Never ships notes for a build that failed review", isRule: true),
        EvalTask(id: "G10", title: "Answers 'what's in this build?' from tickets", covers: [["ChangelogCollector"]]),
    ]

    /// Two runs per task per variant. Baseline failures: G4 run 1, G7 run 2,
    /// G10 run 1. Folded failures: G5 run 2, G7 run 2.
    public static let evalResults: [EvalResult] = {
        let baselineFails: Set<String> = ["G4#1", "G7#2", "G10#1"]
        let foldedFails: Set<String> = ["G5#2", "G7#2"]
        var rows: [EvalResult] = []
        for task in evalTasks {
            for run in 1...2 {
                let key = "\(task.id)#\(run)"
                rows.append(EvalResult(taskID: task.id, variant: .baseline, run: run, passed: !baselineFails.contains(key)))
                rows.append(EvalResult(taskID: task.id, variant: .folded, run: run, passed: !foldedFails.contains(key)))
            }
        }
        return rows
    }()

    public static let minChainShare = 0.1

    public static func assessments(thresholds: RubricThresholds = .standard) -> [BoundaryAssessment] {
        BoundaryRubric(thresholds: thresholds).assess(topology: topology, traces: traces)
    }

    public static func plan(thresholds: RubricThresholds = .standard) -> FoldPlan {
        FoldPlan.make(topology: topology, traces: traces, assessments: assessments(thresholds: thresholds), thresholds: thresholds, minChainShare: minChainShare)
    }

    public static func gateReport() -> FoldGate.Report {
        let chains = TraceStats(traces: traces, topology: topology).chains(minShare: minChainShare)
        return FoldGate(tasks: evalTasks).evaluate(results: evalResults, productionChains: chains)
    }
}
