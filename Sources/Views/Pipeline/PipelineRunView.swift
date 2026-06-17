import SwiftUI

struct PipelineRunView: View {
    private enum NextAction: Equatable {
        case runStage(PipelineStage)
        case approveCandidate
        case publish
        case completed
    }

    let item: AnimationItem

    @Environment(AnimationStore.self) private var animationStore
    @Environment(RevisionStore.self) private var revisionStore
    private let transitionRules = PipelineTransitionRules()

    @State private var runID: UUID?
    @State private var selectedStage: PipelineStage = .sourceIntake
    @State private var showPublishSheet = false
    @State private var showMoreActions = false

    private var run: PipelineRun? {
        if let runID {
            return revisionStore.run(for: runID)
        }
        return revisionStore.runForItem(item.id)
    }

    var body: some View {
        Group {
            if let run {
                content(run: run)
                    .sheet(isPresented: $showPublishSheet) {
                        PublishSheet(ready: run.readyLottie) {
                            Task {
                                _ = await revisionStore.orchestrator.runStage(.publishHandoff, runID: run.id)
                            }
                        }
                    }
                    .confirmationDialog("More Actions", isPresented: $showMoreActions, titleVisibility: .visible) {
                        moreActions(run)
                    }
                    .onAppear {
                        if selectedStage == .sourceIntake {
                            selectedStage = run.currentStage
                        }
                    }
            } else {
                ProgressView("Preparing pipeline run...")
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppBackground().ignoresSafeArea())
            }
        }
        .task {
            let ensured = await revisionStore.ensureRun(for: item, animationStore: animationStore)
            runID = ensured
        }
        .navigationTitle(item.name)
        #if !targetEnvironment(macCatalyst)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showMoreActions = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 20, weight: .semibold))
                }
                .accessibilityLabel("More Actions")
            }
        }
        .background(AppBackground().ignoresSafeArea())
    }

    private func content(run: PipelineRun) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                PipelineStatusView(run: run, selectedStage: $selectedStage) { _ in }

                nextStepCard(run: run)

                previewPanel

                stageContext(run: run)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
    }

    private func nextStepCard(run: PipelineRun) -> some View {
        let action = nextAction(for: run)
        let selectedStatus = run.status(for: selectedStage)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Next Step")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.textSecondary)

            Text(nextActionTitle(action))
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text("Stage \(selectedStage.rawValue): \(selectedStage.title)")
                Text("•")
                Text(selectedStatus.rawValue.uppercased())
            }
            .font(.caption)
            .foregroundStyle(AppTheme.textMuted)

            if let reason = run.reason(for: selectedStage), selectedStatus != .pass {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(nextActionHint(action))
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)

            Button(nextActionButtonTitle(action)) {
                performNextAction(action, run: run)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(action == .completed)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .appGlassCard(cornerRadius: 14, fillOpacity: 0.1, borderOpacity: 0.2)
    }

    private var previewPanel: some View {
        AnimationPlayerView(item: item)
        .frame(minHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func stageContext(run: PipelineRun) -> some View {
        switch selectedStage {
        case .sourceIntake:
            infoCard(
                title: "Source Intake",
                message: "Source has been attached to this run."
            )

        case .canonicalization:
            if let reason = run.reason(for: .canonicalization) {
                CanonicalizationResultView(
                    message: reason,
                    isError: run.status(for: .canonicalization) != .pass
                )
            } else {
                infoCard(
                    title: "Canonicalization",
                    message: "Run this stage to normalize source data."
                )
            }

        case .draftGeneration:
            infoCard(
                title: "Draft Generation",
                message: run.status(for: .draftGeneration) == .pass
                    ? "Draft artifact prepared."
                    : "Run this stage to create draft JSON."
            )

        case .syntaxGate, .motionSemanticGate, .runtimeGate:
            GateResultsCard(gateResult: run.gateResult)

        case .issueResolutionLoop:
            IssueResolutionPanel(
                run: run,
                selectedStage: selectedStage,
                onResolve: {
                    Task { _ = await revisionStore.orchestrator.runStage(.issueResolutionLoop, runID: run.id) }
                },
                onReRunGates: {
                    Task {
                        _ = await revisionStore.orchestrator.runStage(.syntaxGate, runID: run.id)
                        _ = await revisionStore.orchestrator.runStage(.motionSemanticGate, runID: run.id)
                        _ = await revisionStore.orchestrator.runStage(.runtimeGate, runID: run.id)
                    }
                },
                onRollback: {
                    if let rev = run.latestPassingRevisionID {
                        Task { _ = await revisionStore.orchestrator.rollback(runID: run.id, to: rev) }
                    }
                }
            )

        case .releaseCandidate:
            if let candidate = run.readyCandidate {
                ReleaseCandidateView(candidate: candidate) {
                    _ = revisionStore.approveCandidate(runID: run.id)
                }
            } else {
                infoCard(
                    title: "Release Candidate",
                    message: "Run stage 8 after all gates pass."
                )
            }

        case .publishHandoff:
            if let ready = run.readyLottie {
                infoCard(
                    title: "Publish Ready",
                    message: "Checksum: \(ready.checksum.prefix(12))…"
                )
            } else {
                infoCard(
                    title: "Publish",
                    message: "Approve candidate, then publish."
                )
            }
        }
    }

    @ViewBuilder
    private func moreActions(_ run: PipelineRun) -> some View {
        let next = nextAction(for: run)

        if case .runStage(let nextStage) = next, nextStage != selectedStage {
            Button("Run Selected Stage") {
                runSelectedStage(run)
            }
            .disabled(!transitionRules.canEnter(selectedStage, in: run))
        }

        if run.readyCandidate != nil, run.readyCandidate?.approvedAt == nil {
            Button("Approve Candidate") {
                _ = revisionStore.approveCandidate(runID: run.id)
            }
        }

        if run.readyCandidate?.approvedAt != nil {
            Button("Publish") {
                showPublishSheet = true
            }
        }

        Button("Rollback") {
            if let revisionID = run.latestPassingRevisionID {
                Task {
                    _ = await revisionStore.orchestrator.rollback(runID: run.id, to: revisionID)
                }
            }
        }
        .disabled(run.latestPassingRevisionID == nil)
    }

    private func nextAction(for run: PipelineRun) -> NextAction {
        if run.status(for: .sourceIntake) != .pass {
            return .runStage(.sourceIntake)
        }
        if run.status(for: .canonicalization) != .pass {
            return .runStage(.canonicalization)
        }
        if run.status(for: .draftGeneration) != .pass {
            return .runStage(.draftGeneration)
        }

        let hasGateFailure =
            run.status(for: .syntaxGate) == .fail
            || run.status(for: .motionSemanticGate) == .fail
            || run.status(for: .runtimeGate) == .fail
            || run.currentStage == .issueResolutionLoop

        if hasGateFailure {
            return .runStage(.issueResolutionLoop)
        }

        if run.status(for: .syntaxGate) != .pass {
            return .runStage(.syntaxGate)
        }
        if run.status(for: .motionSemanticGate) != .pass {
            return .runStage(.motionSemanticGate)
        }
        if run.status(for: .runtimeGate) != .pass {
            return .runStage(.runtimeGate)
        }
        if run.readyCandidate == nil {
            return .runStage(.releaseCandidate)
        }
        if run.readyCandidate?.approvedAt == nil {
            return .approveCandidate
        }
        if run.status(for: .publishHandoff) != .pass {
            return .publish
        }
        return .completed
    }

    private func nextActionTitle(_ action: NextAction) -> String {
        switch action {
        case .runStage(let stage):
            return "Run Stage \(stage.rawValue): \(stage.title)"
        case .approveCandidate:
            return "Approve Release Candidate"
        case .publish:
            return "Publish Release"
        case .completed:
            return "Pipeline Completed"
        }
    }

    private func nextActionHint(_ action: NextAction) -> String {
        switch action {
        case .runStage(let stage):
            if stage == .issueResolutionLoop {
                return "Fix issues and re-run the required checks."
            }
            return "Run this stage to move forward."
        case .approveCandidate:
            return "All gates passed. Manual approval is required."
        case .publish:
            return "Candidate approved and ready for publish."
        case .completed:
            return "No action needed."
        }
    }

    private func nextActionButtonTitle(_ action: NextAction) -> String {
        switch action {
        case .runStage(let stage):
            return "Run Stage \(stage.rawValue)"
        case .approveCandidate:
            return "Approve Candidate"
        case .publish:
            return "Publish"
        case .completed:
            return "Completed"
        }
    }

    private func performNextAction(_ action: NextAction, run: PipelineRun) {
        switch action {
        case .runStage(let stage):
            selectedStage = stage
            Task { _ = await revisionStore.orchestrator.runStage(stage, runID: run.id) }
        case .approveCandidate:
            _ = revisionStore.approveCandidate(runID: run.id)
        case .publish:
            showPublishSheet = true
        case .completed:
            break
        }
    }

    private func runSelectedStage(_ run: PipelineRun) {
        Task { _ = await revisionStore.orchestrator.runStage(selectedStage, runID: run.id) }
    }

    private func infoCard(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .appGlassCard(cornerRadius: 14, fillOpacity: 0.1, borderOpacity: 0.2)
    }
}
