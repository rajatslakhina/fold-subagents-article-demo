import XCTest
@testable import AgentBoundaryKit

final class TraceStatsTests: XCTestCase {
    func testSampleShares() {
        let stats = TraceStats(traces: SampleReleaseCopilot.traces, topology: SampleReleaseCopilot.topology)
        XCTAssertEqual(stats.taskCount, 20)
        XCTAssertEqual(stats.callShare["IntentRouter"], 1.0)
        XCTAssertEqual(stats.callShare["ReleaseNotesWriter"], 0.5)
        XCTAssertEqual(stats.callShare["ChangelogCollector"], 0.4)
        XCTAssertEqual(stats.parallelShare["LocalizationReviewer"], 1.0)
        XCTAssertEqual(stats.parallelShare["CrashTriage"], 0.0)
        XCTAssertEqual(stats.pairShare[AgentPair("ChangelogCollector", "ReleaseNotesWriter")], 0.4)
        XCTAssertEqual(stats.pairShare[AgentPair("CrashTriage", "ReleaseNotesWriter")], 0.1)
    }

    func testRouterIsNeverPaired() {
        let stats = TraceStats(traces: SampleReleaseCopilot.traces, topology: SampleReleaseCopilot.topology)
        XCTAssertFalse(stats.pairShare.keys.contains { $0.from == "IntentRouter" || $0.to == "IntentRouter" })
    }

    func testParallelFanOutCountsAsOneStep() {
        let stats = TraceStats(traces: SampleReleaseCopilot.traces, topology: SampleReleaseCopilot.topology)
        XCTAssertNil(stats.pairShare[AgentPair("LocalizationReviewer", "LocalizationReviewer")])
        XCTAssertEqual(stats.pairShare[AgentPair("LocalizationReviewer", "MetadataChecker")], 0.2)
    }

    func testChainsAreOrderedByShareThenName() {
        let stats = TraceStats(traces: SampleReleaseCopilot.traces, topology: SampleReleaseCopilot.topology)
        XCTAssertEqual(stats.chains(minShare: 0.1), [
            AgentPair("ChangelogCollector", "ReleaseNotesWriter"),
            AgentPair("LocalizationReviewer", "MetadataChecker"),
            AgentPair("ReleaseNotesWriter", "MetadataChecker"),
            AgentPair("CrashTriage", "ReleaseNotesWriter"),
        ])
    }

    func testEntityOverlap() {
        let stats = TraceStats(traces: SampleReleaseCopilot.traces, topology: SampleReleaseCopilot.topology)
        XCTAssertEqual(stats.entityOverlap("ChangelogCollector", "ReleaseNotesWriter"), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(stats.entityOverlap("ReviewReplyDrafter", "CrashTriage"), 0)
        XCTAssertEqual(stats.entityOverlap("Unknown", "AlsoUnknown"), 0)
    }

    func testEmptyTracesDoNotDivideByZero() {
        let stats = TraceStats(traces: [], topology: SampleReleaseCopilot.topology)
        XCTAssertEqual(stats.taskCount, 0)
        XCTAssertTrue(stats.callShare.isEmpty)
        XCTAssertTrue(stats.chains(minShare: 0).isEmpty)
    }
}

final class BoundaryRubricTests: XCTestCase {
    private func verdicts(_ thresholds: RubricThresholds = .standard) -> [String: BoundaryAssessment] {
        Dictionary(uniqueKeysWithValues: SampleReleaseCopilot.assessments(thresholds: thresholds).map { ($0.agent, $0) })
    }

    func testFourOfSevenFold() {
        let all = SampleReleaseCopilot.assessments()
        XCTAssertEqual(all.count, 7)
        XCTAssertEqual(all.filter(\.verdict.isFold).map(\.agent).sorted(),
                       ["ChangelogCollector", "IntentRouter", "MetadataChecker", "ReleaseNotesWriter"])
    }

    func testCoupledPairFoldsTogether() {
        let byID = verdicts()
        XCTAssertEqual(byID["ChangelogCollector"]?.verdict, .foldWith(partner: "ReleaseNotesWriter", pairShare: 0.4))
        XCTAssertEqual(byID["ReleaseNotesWriter"]?.verdict, .foldWith(partner: "ChangelogCollector", pairShare: 0.4))
        XCTAssertEqual(byID["MetadataChecker"]?.verdict, .fold)
        XCTAssertEqual(byID["IntentRouter"]?.verdict, .fold)
    }

    func testKeepReasons() {
        let byID = verdicts()
        XCTAssertEqual(byID["CrashTriage"]?.verdict, .keep([.contextBloat(foldedTokens: 158_000, budget: 120_000)]))
        XCTAssertEqual(byID["LocalizationReviewer"]?.verdict, .keep([.parallelFanOut(share: 1.0)]))
        XCTAssertEqual(byID["ReviewReplyDrafter"]?.verdict, .keep([.conflictingInstructions(keys: ["tone"])]))
    }

    func testOnlyTheConflictIsFixable() {
        let byID = verdicts()
        XCTAssertEqual(byID["ReviewReplyDrafter"]?.foldsAfterFix, true)
        XCTAssertEqual(byID["CrashTriage"]?.foldsAfterFix, false)
        XCTAssertEqual(byID["LocalizationReviewer"]?.foldsAfterFix, false)
        XCTAssertEqual(byID["MetadataChecker"]?.foldsAfterFix, false)
    }

    func testCompressionRatioShowsLossyHandoff() {
        let byID = verdicts()
        XCTAssertEqual(byID["CrashTriage"]?.compressionRatio ?? 0, 140_000.0 / 1_200.0, accuracy: 1e-9)
        XCTAssertEqual(byID["ChangelogCollector"]?.compressionRatio ?? 0, 9_000.0 / 800.0, accuracy: 1e-9)
    }

    func testBiggerContextBudgetFoldsCrashTriage() {
        let byID = verdicts(RubricThresholds(contextBudgetTokens: 200_000))
        XCTAssertEqual(byID["CrashTriage"]?.verdict.isFold, true)
    }

    func testToolBudgetKeepsAWideSpecialist() {
        let wide = AgentSpec(id: "Wide", owner: "X", tools: (1...10).map { "t\($0)" }, workingSetTokens: 100)
        let topology = Topology(mainTools: ["a", "b"], mainRules: [:], mainContextTokens: 1_000, subagents: [wide])
        let result = BoundaryRubric(thresholds: RubricThresholds(toolBudget: 8)).assess(topology: topology, traces: [])
        XCTAssertEqual(result.first?.verdict, .keep([.toolSelection(foldedTools: 12, budget: 8)]))
    }

    func testAgentThatTalksToUserIsKept() {
        let agent = AgentSpec(id: "Concierge", owner: "Support", workingSetTokens: 10, talksToUser: true)
        let topology = Topology(mainTools: [], mainRules: [:], mainContextTokens: 0, subagents: [agent])
        let result = BoundaryRubric().assess(topology: topology, traces: [])
        XCTAssertEqual(result.first?.verdict, .keep([.ownsConversation]))
    }

    func testDoesNotMergeWithAKeptPartner() {
        // B always follows A, but B owns the conversation, so A folds alone.
        let a = AgentSpec(id: "A", owner: "X", workingSetTokens: 10)
        let b = AgentSpec(id: "B", owner: "Y", workingSetTokens: 10, talksToUser: true)
        let topology = Topology(mainTools: [], mainRules: [:], mainContextTokens: 0, subagents: [a, b])
        let traces = (1...4).map { TaskTrace(id: "t\($0)", invocations: [
            Invocation(agent: "A", handoffOutTokens: 10), Invocation(agent: "B", handoffOutTokens: 10),
        ]) }
        let result = BoundaryRubric().assess(topology: topology, traces: traces)
        XCTAssertEqual(result.first { $0.agent == "A" }?.verdict, .fold)
    }

    func testZeroHandoffGivesZeroRatioNotInfinity() {
        let agent = AgentSpec(id: "Silent", owner: "X", workingSetTokens: 500)
        let topology = Topology(mainTools: [], mainRules: [:], mainContextTokens: 0, subagents: [agent])
        let trace = TaskTrace(id: "t", invocations: [Invocation(agent: "Silent", handoffOutTokens: 0)])
        XCTAssertEqual(BoundaryRubric().assess(topology: topology, traces: [trace]).first?.compressionRatio, 0)
    }

    func testNegativeInputsAreClamped() {
        let agent = AgentSpec(id: "N", owner: "X", workingSetTokens: -5)
        XCTAssertEqual(agent.workingSetTokens, 0)
        XCTAssertEqual(Invocation(agent: "N", handoffOutTokens: -1).handoffOutTokens, 0)
    }
}

final class FoldPlanTests: XCTestCase {
    func testStepsAreMostUsedFirstWithPairsTogether() {
        let plan = SampleReleaseCopilot.plan()
        XCTAssertEqual(plan.steps.map(\.agents), [
            ["IntentRouter"],
            ["ReleaseNotesWriter", "ChangelogCollector"],
            ["MetadataChecker"],
        ])
        XCTAssertEqual(plan.steps.last?.contextAfter, 42_000)
        XCTAssertEqual(plan.steps.last?.toolsAfter, 9)
        XCTAssertTrue(plan.deferred.isEmpty)
        XCTAssertEqual(plan.kept.sorted(), ["CrashTriage", "LocalizationReviewer", "ReviewReplyDrafter"])
    }

    func testStepListsTheChainsItMustCover() {
        let plan = SampleReleaseCopilot.plan()
        guard plan.steps.indices.contains(1) else { return XCTFail("expected a second step") }
        XCTAssertTrue(plan.steps[1].chainsToCover.contains(AgentPair("CrashTriage", "ReleaseNotesWriter")))
        XCTAssertTrue(plan.steps[0].chainsToCover.isEmpty)
    }

    func testOnlyMutualPartnersFoldTogether() {
        // A's strongest partner is B (3 of 14 tasks), but B's is C (5 of 14).
        // A is the most-used agent, yet it must fold alone and B goes with C.
        let specs = ["A", "B", "C"].map { AgentSpec(id: $0, owner: "X", workingSetTokens: 100) }
        let topology = Topology(mainTools: [], mainRules: [:], mainContextTokens: 1_000, subagents: specs)
        func trace(_ id: String, _ agents: [String]) -> TaskTrace {
            TaskTrace(id: id, invocations: agents.map { Invocation(agent: $0, handoffOutTokens: 10) })
        }
        let traces = (1...3).map { trace("ab\($0)", ["A", "B"]) }
            + (1...5).map { trace("bc\($0)", ["B", "C"]) }
            + (1...6).map { trace("a\($0)", ["A"]) }
        let thresholds = RubricThresholds(minPairShare: 0.2)
        let assessments = BoundaryRubric(thresholds: thresholds).assess(topology: topology, traces: traces)
        let byID = Dictionary(uniqueKeysWithValues: assessments.map { ($0.agent, $0.verdict) })
        XCTAssertEqual(byID["A"], .fold)
        XCTAssertEqual(byID["B"], .foldWith(partner: "C", pairShare: 5.0 / 14.0))
        XCTAssertEqual(byID["C"], .foldWith(partner: "B", pairShare: 5.0 / 14.0))
        let plan = FoldPlan.make(topology: topology, traces: traces, assessments: assessments, thresholds: thresholds)
        XCTAssertEqual(plan.steps.map(\.agents), [["A"], ["B", "C"]])
    }

    func testPlanIgnoresAOneSidedPartnerClaim() {
        // Hand-built assessments where X claims Y but Y does not claim X back.
        let specs = ["X", "Y"].map { AgentSpec(id: $0, owner: "O", workingSetTokens: 10) }
        let topology = Topology(mainTools: [], mainRules: [:], mainContextTokens: 0, subagents: specs)
        func assessment(_ id: String, _ verdict: Verdict, _ share: Double) -> BoundaryAssessment {
            BoundaryAssessment(agent: id, role: .specialist, verdict: verdict, callShare: share, parallelShare: 0,
                               compressionRatio: 0, strongestPartner: nil, strongestPairShare: 0, partnerEntityOverlap: 0)
        }
        let plan = FoldPlan.make(topology: topology, traces: [], assessments: [
            assessment("X", .foldWith(partner: "Y", pairShare: 0.5), 0.9),
            assessment("Y", .fold, 0.5),
        ])
        XCTAssertEqual(plan.steps.map(\.agents), [["X"], ["Y"]])
    }

    func testCumulativeBudgetDefersLaterFolds() {
        // Each agent passes the per-agent check; together they would not.
        let thresholds = RubricThresholds(contextBudgetTokens: 30_000)
        let plan = SampleReleaseCopilot.plan(thresholds: thresholds)
        XCTAssertEqual(plan.steps.map(\.agents), [["IntentRouter"], ["MetadataChecker"]])
        XCTAssertEqual(plan.deferred, ["ReleaseNotesWriter", "ChangelogCollector"])
    }
}

final class FoldGateTests: XCTestCase {
    func testMeanGoesUpAndTheGateStillBlocks() {
        let report = SampleReleaseCopilot.gateReport()
        XCTAssertEqual(report.baselinePassRate, 0.85, accuracy: 1e-9)
        XCTAssertEqual(report.foldedPassRate, 0.90, accuracy: 1e-9)
        XCTAssertEqual(report.flips.map(\.taskID), ["G5"])
        XCTAssertTrue(report.meanHidesRegression)
        XCTAssertFalse(report.canShip)
    }

    func testUncoveredChainIsReported() {
        let report = SampleReleaseCopilot.gateReport()
        XCTAssertTrue(report.issues.contains(.uncoveredChain(AgentPair("CrashTriage", "ReleaseNotesWriter"))))
        XCTAssertEqual(report.issues.count, 2)
    }

    func testTaskThatWasAlreadyFlakyIsNotAFlip() {
        // G7 failed a baseline run too, so its folded failure is not new.
        XCTAssertFalse(SampleReleaseCopilot.gateReport().flips.contains { $0.taskID == "G7" })
    }

    func testOneRunIsNotEnough() {
        let task = EvalTask(id: "T", title: "t", covers: [["A", "B"]])
        let results = [
            EvalResult(taskID: "T", variant: .baseline, run: 1, passed: true),
            EvalResult(taskID: "T", variant: .folded, run: 1, passed: true),
        ]
        let report = FoldGate(tasks: [task]).evaluate(results: results, productionChains: [AgentPair("A", "B")])
        XCTAssertEqual(report.issues, [
            .tooFewRuns(taskID: "T", variant: .baseline, runs: 1),
            .tooFewRuns(taskID: "T", variant: .folded, runs: 1),
        ])
    }

    func testMissingResultsAndEmptyRates() {
        let report = FoldGate(tasks: [EvalTask(id: "T", title: "t")]).evaluate(results: [], productionChains: [])
        XCTAssertEqual(report.baselinePassRate, 0)
        XCTAssertEqual(report.issues, [.missingResults(taskID: "T", variant: .baseline), .missingResults(taskID: "T", variant: .folded)])
    }

    func testCleanFoldShips() {
        let task = EvalTask(id: "T", title: "t", covers: [["A", "B"]])
        let results = (1...2).flatMap { run in
            Variant.allCases.map { EvalResult(taskID: "T", variant: $0, run: run, passed: true) }
        }
        let report = FoldGate(tasks: [task]).evaluate(results: results, productionChains: [AgentPair("A", "B")])
        XCTAssertTrue(report.canShip)
        XCTAssertFalse(report.meanHidesRegression)
    }

    func testCoverageNeedsAdjacencyInOrder() {
        let task = EvalTask(id: "T", title: "t", covers: [["A", "C", "B"]])
        XCTAssertFalse(task.covers(AgentPair("A", "B")))
        XCTAssertTrue(task.covers(AgentPair("C", "B")))
        XCTAssertFalse(task.covers(AgentPair("B", "C")))
    }
}
