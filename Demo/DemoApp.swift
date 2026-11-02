import SwiftUI
import AgentBoundaryKit

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments drive the CI screenshots: `-tab boundaries|plan|gate`,
/// `-budget 40...200` (context budget in thousands of tokens).
struct RootView: View {
    @State private var tab: String = UserDefaults.standard.string(forKey: "tab") ?? "boundaries"

    var body: some View {
        TabView(selection: $tab) {
            BoundariesView()
                .tabItem { Label("Boundaries", systemImage: "square.split.2x2") }
                .tag("boundaries")
            PlanView()
                .tabItem { Label("Fold plan", systemImage: "arrow.triangle.merge") }
                .tag("plan")
            GateView()
                .tabItem { Label("Eval gate", systemImage: "checkmark.seal") }
                .tag("gate")
        }
    }
}

// MARK: - Boundaries

struct BoundariesView: View {
    @State private var contextBudget: Double = {
        let fromLaunch = UserDefaults.standard.integer(forKey: "budget")
        return Double(fromLaunch > 0 ? min(max(fromLaunch, 40), 200) : 120)
    }()
    private let topology = SampleReleaseCopilot.topology

    private var assessments: [BoundaryAssessment] {
        SampleReleaseCopilot.assessments(thresholds: RubricThresholds(contextBudgetTokens: Int(contextBudget) * 1_000))
    }

    var body: some View {
        NavigationStack {
            List {
                let all = assessments
                Section {
                    HStack {
                        Metric(value: "\(all.filter(\.verdict.isFold).count)/\(all.count)", label: "fold")
                        Metric(value: "\(all.filter { !$0.verdict.isFold && !$0.foldsAfterFix }.count)", label: "keep")
                        Metric(value: "\(all.filter(\.foldsAfterFix).count)", label: "fold after a fix")
                    }
                    VStack(alignment: .leading) {
                        Text("Context budget: \(Int(contextBudget))k tokens").font(.subheadline)
                        Slider(value: $contextBudget, in: 40...200, step: 10)
                    }
                } footer: {
                    Text("Sample: an iOS release copilot with a router and six specialists, 20 synthetic task traces. A boundary is kept only for parallel fan-out, context it can't share, tool overload, a conflicting prompt, or owning the conversation.")
                }
                Section("Subagents") {
                    ForEach(all) { item in
                        AssessmentRow(item: item, owner: topology.agent(item.agent)?.owner ?? "")
                    }
                }
            }
            .navigationTitle("Agent boundaries")
        }
    }
}

struct AssessmentRow: View {
    let item: BoundaryAssessment
    let owner: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.agent).font(.subheadline.weight(.semibold))
                Spacer()
                Badge(text: badgeText, color: badgeColor)
            }
            Text("\(owner) · \(item.role.rawValue) · called in \(pct(item.callShare)) of tasks")
                .font(.caption)
                .foregroundStyle(.secondary)
            switch item.verdict {
            case .fold:
                Text(item.role == .specialist ? "No reason to keep the boundary" : "The model routes and plans inside its own loop")
                    .font(.caption2).foregroundStyle(.secondary)
            case .foldWith(let partner, let share):
                Text("Fold together with \(partner): adjacent in \(pct(share)) of tasks")
                    .font(.caption2).foregroundStyle(.secondary)
            case .keep(let reasons):
                ForEach(reasons, id: \.self) { reason in
                    Text(reason.description).font(.caption2.monospaced()).foregroundStyle(reason.isFixable ? Color.orange : Color.primary)
                }
            }
            if item.compressionRatio >= 20 {
                Text("Hands back 1 token for every \(Int(item.compressionRatio.rounded())) it reads")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var badgeText: String {
        if item.foldsAfterFix { return "fix, then fold" }
        return item.verdict.isFold ? "fold" : "keep"
    }

    private var badgeColor: Color {
        if item.foldsAfterFix { return .orange }
        return item.verdict.isFold ? .green : .blue
    }
}

// MARK: - Plan

struct PlanView: View {
    private let plan = SampleReleaseCopilot.plan()

    var body: some View {
        NavigationStack {
            List {
                ForEach(plan.steps) { step in
                    Section("Step \(step.index)") {
                        Text(step.agents.joined(separator: " + ")).font(.subheadline.weight(.semibold))
                        HStack {
                            Metric(value: "\(step.contextAfter / 1_000)k", label: "main-loop context after")
                            Metric(value: "\(step.toolsAfter)", label: "tools after")
                        }
                        if step.chainsToCover.isEmpty {
                            Text("No production chains touch this step").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Eval must cover:").font(.caption.weight(.semibold))
                            ForEach(step.chainsToCover, id: \.self) { chain in
                                Text(chain.description).font(.caption.monospaced())
                            }
                        }
                    }
                }
                Section("Kept") {
                    ForEach(plan.kept, id: \.self) { Text($0).font(.subheadline) }
                }
                if !plan.deferred.isEmpty {
                    Section("Deferred (cumulative budget)") {
                        ForEach(plan.deferred, id: \.self) { Text($0) }
                    }
                }
            }
            .navigationTitle("Fold plan")
        }
    }
}

// MARK: - Gate

struct GateView: View {
    private let report = SampleReleaseCopilot.gateReport()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Metric(value: pct(report.baselinePassRate), label: "baseline pass rate")
                        Metric(value: pct(report.foldedPassRate), label: "folded pass rate")
                    }
                    HStack {
                        Image(systemName: report.canShip ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(report.canShip ? Color.green : Color.red)
                        Text(report.canShip ? "Ship the fold" : "Blocked")
                            .font(.headline)
                        if report.meanHidesRegression {
                            Badge(text: "mean went up anyway", color: .orange)
                        }
                    }
                } footer: {
                    Text("10 golden tasks × 2 runs per variant. A task that passed every baseline run and fails any folded run blocks the step, whatever the mean says.")
                }
                Section("Issues") {
                    ForEach(report.issues, id: \.self) { issue in
                        Text(issue.description).font(.caption.monospaced())
                    }
                }
                Section("Flipped tasks") {
                    ForEach(report.flips) { flip in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(flip.taskID). \(flip.title)").font(.subheadline.weight(.semibold))
                            Text("baseline \(flip.baselinePasses)/\(flip.baselineRuns) · folded \(flip.foldedPasses)/\(flip.foldedRuns)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Eval gate")
        }
    }
}

// MARK: - Shared

struct Metric: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}

func pct(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}
