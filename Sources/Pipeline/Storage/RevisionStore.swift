import Foundation
import Observation

@MainActor
@Observable
final class RevisionStore {
    private(set) var runs: [PipelineRun] = []
    private(set) var itemIndex: [UUID: UUID] = [:]
    private(set) var hasLoaded = false

    private let rules = PipelineTransitionRules()
    private let canonicalizationService = CanonicalizationService()
    private let syntaxGate = SyntaxGate()
    private let motionGate = MotionSemanticGate()
    private let runtimeGate = RuntimeGate()
    private let reportBuilder = QAReportBuilder()
    private let diffService = RevisionDiffService()
    private let issueResolutionService = IssueResolutionService()
    private let rollbackService = RollbackService()
    private let releaseCandidateService = ReleaseCandidateService()
    private let publishService = PublishHandoffService()

    var orchestrator: PipelineOrchestrator {
        PipelineOrchestrator(revisionStore: self)
    }

    var pipelineRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent("LottiePipeline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let runsRoot = root.appendingPathComponent("runs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: runsRoot.path) {
            try? FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        }
        return root
    }

    private var indexURL: URL {
        pipelineRoot.appendingPathComponent("index.json")
    }

    func loadIfNeeded(animationStore: AnimationStore) async {
        guard !hasLoaded else { return }
        loadPersistedRuns()
        await migrateLegacyIfNeeded(animationStore: animationStore)
        hasLoaded = true
    }

    func run(for runID: UUID) -> PipelineRun? {
        runs.first(where: { $0.id == runID })
    }

    func runForItem(_ itemID: UUID) -> PipelineRun? {
        guard let runID = itemIndex[itemID] else { return nil }
        return run(for: runID)
    }

    func runID(for itemID: UUID) -> UUID? {
        itemIndex[itemID]
    }

    func ensureRun(for item: AnimationItem, animationStore: AnimationStore) async -> UUID {
        if let existing = itemIndex[item.id] {
            return existing
        }

        let source = SourceArtifact(
            id: UUID(),
            sourceType: .lottieJSON,
            payloadRef: animationStore.fileURL(for: item).path,
            metadata: [
                "item_id": item.id.uuidString,
                "file_name": item.fileName,
                "created_from": "legacy_animation_item"
            ]
        )

        var run = PipelineRun(displayName: item.name, sourceArtifact: source)
        markStage(
            .sourceIntake,
            status: .pass,
            reason: "Legacy item imported into pipeline",
            run: &run
        )
        appendRevision(for: .sourceIntake, status: .pass, reason: "Legacy migration", run: &run)

        runs.append(run)
        itemIndex[item.id] = run.id
        persist(run)
        persistIndex()
        return run.id
    }

    func createRun(
        for item: AnimationItem,
        sourceType: SourceType,
        sourceData: Data,
        sourceFileName: String,
        metadata: [String: String] = [:]
    ) async throws -> UUID {
        if let existing = itemIndex[item.id] {
            return existing
        }

        let runID = UUID()
        let runDir = runDirectory(for: runID)
        let ext = defaultExtension(for: sourceType)
        let sourceURL = runDir.appendingPathComponent("source.\(ext)")

        try sourceData.write(to: sourceURL, options: .atomic)

        var sourceMetadata = metadata
        sourceMetadata["item_id"] = item.id.uuidString
        sourceMetadata["created_from"] = "multi_source_intake"
        sourceMetadata["original_file_name"] = sourceFileName

        let source = SourceArtifact(
            id: UUID(),
            sourceType: sourceType,
            payloadRef: sourceURL.path,
            metadata: sourceMetadata
        )

        var run = PipelineRun(id: runID, displayName: item.name, sourceArtifact: source)
        markStage(
            .sourceIntake,
            status: .pass,
            reason: "Source accepted from \(sourceType.title)",
            run: &run
        )
        appendRevision(for: .sourceIntake, status: .pass, reason: "Multi-source intake", run: &run)

        runs.append(run)
        itemIndex[item.id] = runID
        persist(run)
        persistIndex()
        return runID
    }

    func approveCandidate(runID: UUID) -> Bool {
        guard let idx = runs.firstIndex(where: { $0.id == runID }),
              let candidate = runs[idx].readyCandidate else {
            return false
        }

        runs[idx].readyCandidate = ReadyCandidate(
            id: candidate.id,
            revisionID: candidate.revisionID,
            gateResults: candidate.gateResults,
            riskFlags: candidate.riskFlags,
            approvedAt: .now
        )
        markStage(.releaseCandidate, status: .pass, reason: "Candidate approved", run: &runs[idx])
        persist(runs[idx])
        return true
    }

    func rollback(runID: UUID, to revisionID: UUID) async -> Bool {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else { return false }
        let success = rollbackService.rollback(run: &runs[idx], to: revisionID)
        if success {
            markStage(.issueResolutionLoop, status: .pass, reason: "Rollback applied", run: &runs[idx])
            persist(runs[idx])
        }
        return success
    }

    func runStage(_ stage: PipelineStage, runID: UUID) async -> StageResultStatus {
        guard let idx = runs.firstIndex(where: { $0.id == runID }) else {
            return .fail
        }

        guard let context = context(for: runs[idx]) else {
            markStage(stage, status: .fail, reason: "Invalid source reference", run: &runs[idx])
            persist(runs[idx])
            return .fail
        }

        guard rules.canEnter(stage, in: runs[idx]) else {
            markStage(stage, status: .fail, reason: "Entry criteria not met", run: &runs[idx])
            persist(runs[idx])
            return .fail
        }

        if consumesRetryBudget(for: stage, run: runs[idx]) {
            if rules.retryBudget(for: stage) <= runs[idx].retryCount(for: stage) {
                markStage(stage, status: .degraded, reason: "Retry budget exhausted", run: &runs[idx])
                runs[idx].currentStage = .issueResolutionLoop
                persist(runs[idx])
                return .degraded
            }
            incrementRetry(stage, run: &runs[idx])
        }

        switch stage {
        case .sourceIntake:
            return await runSourceIntake(at: idx, context: context)
        case .canonicalization:
            return await runCanonicalization(at: idx, context: context)
        case .draftGeneration:
            return await runDraftGeneration(at: idx, context: context)
        case .syntaxGate:
            return await runSyntaxGate(at: idx, context: context)
        case .motionSemanticGate:
            return await runMotionGate(at: idx, context: context)
        case .runtimeGate:
            return await runRuntimeGate(at: idx, context: context)
        case .issueResolutionLoop:
            return await runIssueResolution(at: idx)
        case .releaseCandidate:
            return await runReleaseCandidate(at: idx)
        case .publishHandoff:
            return await runPublish(at: idx, context: context)
        }
    }

    private func runSourceIntake(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        let exists = FileManager.default.fileExists(atPath: context.sourceURL.path)
        let status: StageResultStatus = exists ? .pass : .fail
        let reason = exists ? "Source accepted" : "Source file is missing"
        markStage(.sourceIntake, status: status, reason: reason, run: &runs[idx])
        appendRevision(for: .sourceIntake, status: status, reason: reason, run: &runs[idx])
        runs[idx].currentStage = exists ? .sourceIntake : .issueResolutionLoop
        persist(runs[idx])
        return status
    }

    private func runCanonicalization(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        do {
            let snapshot = try canonicalizationService.canonicalize(
                sourceType: runs[idx].sourceArtifact.sourceType,
                sourceURL: context.sourceURL
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(
                    to: context.runDirectory.appendingPathComponent("canonical.json"),
                    options: .atomic
                )
            }

            markStage(.canonicalization, status: .pass, reason: "Canonical representation prepared", run: &runs[idx])
            appendRevision(for: .canonicalization, status: .pass, reason: "Canonicalization completed", run: &runs[idx])
            runs[idx].currentStage = .canonicalization
            persist(runs[idx])
            return .pass
        } catch {
            markStage(
                .canonicalization,
                status: .fail,
                reason: "Canonicalization failed: \(error.localizedDescription)",
                run: &runs[idx]
            )
            appendRevision(for: .canonicalization, status: .fail, reason: "Canonicalization failed", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }
    }

    private func runDraftGeneration(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        guard let canonicalData = try? Data(contentsOf: context.runDirectory.appendingPathComponent("canonical.json")),
              let canonical = try? JSONDecoder().decode(CanonicalizationSnapshot.self, from: canonicalData) else {
            markStage(.draftGeneration, status: .fail, reason: "Draft generation failed", run: &runs[idx])
            appendRevision(for: .draftGeneration, status: .fail, reason: "Missing canonical representation", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }

        do {
            let draftURL = try canonicalizationService.generateDraftJSON(
                sourceType: runs[idx].sourceArtifact.sourceType,
                sourceURL: context.sourceURL,
                canonical: canonical,
                runDirectory: context.runDirectory
            )

            let draft = DraftArtifact(
                id: UUID(),
                revisionID: runs[idx].latestRevisionID ?? UUID(),
                lottieJSONRef: draftURL.path,
                provenance: ["generator": "deterministic_m2"]
            )
            runs[idx].drafts.append(draft)
            markStage(.draftGeneration, status: .pass, reason: "Draft artifact created", run: &runs[idx])
            appendRevision(for: .draftGeneration, status: .pass, reason: "Draft generation completed", run: &runs[idx])
            runs[idx].currentStage = .draftGeneration
            persist(runs[idx])
            return .pass
        } catch {
            markStage(
                .draftGeneration,
                status: .fail,
                reason: "Draft generation failed: \(error.localizedDescription)",
                run: &runs[idx]
            )
            appendRevision(for: .draftGeneration, status: .fail, reason: "Draft generation failed", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }
    }

    private func runSyntaxGate(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        guard let jsonURL = effectiveDraftURL(for: runs[idx], context: context) else {
            markStage(.syntaxGate, status: .fail, reason: "No draft available for syntax gate", run: &runs[idx])
            appendRevision(for: .syntaxGate, status: .fail, reason: "Missing draft JSON", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }

        let findings = syntaxGate.evaluate(jsonURL: jsonURL)
        return finalizeGate(
            stage: .syntaxGate,
            findings: findings,
            at: idx,
            context: context,
            reasonOnPass: "Syntax checks passed",
            reasonOnFail: "Syntax checks failed"
        )
    }

    private func runMotionGate(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        guard let jsonURL = effectiveDraftURL(for: runs[idx], context: context) else {
            markStage(.motionSemanticGate, status: .fail, reason: "No draft available for motion gate", run: &runs[idx])
            appendRevision(for: .motionSemanticGate, status: .fail, reason: "Missing draft JSON", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }

        let findings = motionGate.evaluate(jsonURL: jsonURL)
        return finalizeGate(
            stage: .motionSemanticGate,
            findings: findings,
            at: idx,
            context: context,
            reasonOnPass: "Motion semantic checks passed",
            reasonOnFail: "Motion semantic checks failed"
        )
    }

    private func runRuntimeGate(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        guard let jsonURL = effectiveDraftURL(for: runs[idx], context: context) else {
            markStage(.runtimeGate, status: .fail, reason: "No draft available for runtime gate", run: &runs[idx])
            appendRevision(for: .runtimeGate, status: .fail, reason: "Missing draft JSON", run: &runs[idx])
            runs[idx].currentStage = .issueResolutionLoop
            persist(runs[idx])
            return .fail
        }

        let findings = runtimeGate.evaluate(jsonURL: jsonURL)
        return finalizeGate(
            stage: .runtimeGate,
            findings: findings,
            at: idx,
            context: context,
            reasonOnPass: "Runtime checks passed",
            reasonOnFail: "Runtime checks failed"
        )
    }

    private func runIssueResolution(at idx: Int) async -> StageResultStatus {
        let revision = issueResolutionService.applyManualResolution(to: &runs[idx], actor: "user")
        markStage(.issueResolutionLoop, status: .pass, reason: "Issue resolution revision \(revision.id.uuidString)", run: &runs[idx])
        resetRetryBudgets(run: &runs[idx])
        persist(runs[idx])
        return .pass
    }

    private func runReleaseCandidate(at idx: Int) async -> StageResultStatus {
        let candidate = releaseCandidateService.build(for: runs[idx])
        runs[idx].readyCandidate = candidate

        if candidate.riskFlags.isEmpty {
            markStage(.releaseCandidate, status: .retryable, reason: "Awaiting manual approval", run: &runs[idx])
            runs[idx].currentStage = .releaseCandidate
            appendRevision(for: .releaseCandidate, status: .retryable, reason: "Candidate prepared", run: &runs[idx])
            persist(runs[idx])
            return .retryable
        }

        markStage(.releaseCandidate, status: .fail, reason: "Risk flags unresolved", run: &runs[idx])
        runs[idx].currentStage = .issueResolutionLoop
        appendRevision(for: .releaseCandidate, status: .fail, reason: "Candidate rejected by risk flags", run: &runs[idx])
        persist(runs[idx])
        return .fail
    }

    private func runPublish(at idx: Int, context: PipelineRunContext) async -> StageResultStatus {
        guard runs[idx].readyCandidate?.approvedAt != nil else {
            markStage(.publishHandoff, status: .fail, reason: "Candidate must be approved", run: &runs[idx])
            persist(runs[idx])
            return .fail
        }

        guard let jsonURL = effectiveDraftURL(for: runs[idx], context: context) else {
            markStage(.publishHandoff, status: .fail, reason: "No draft available for publish", run: &runs[idx])
            persist(runs[idx])
            return .fail
        }

        do {
            _ = try publishService.publish(
                run: &runs[idx],
                runDirectory: context.runDirectory,
                sourceURL: jsonURL
            )
            markStage(.publishHandoff, status: .pass, reason: "ReadyLottie exported", run: &runs[idx])
            appendRevision(for: .publishHandoff, status: .pass, reason: "Publish completed", run: &runs[idx])
            runs[idx].currentStage = .publishHandoff
            persist(runs[idx])
            return .pass
        } catch {
            markStage(.publishHandoff, status: .fail, reason: "Publish failed: \(error.localizedDescription)", run: &runs[idx])
            persist(runs[idx])
            return .fail
        }
    }

    private func finalizeGate(
        stage: PipelineStage,
        findings: [QAFinding],
        at idx: Int,
        context: PipelineRunContext,
        reasonOnPass: String,
        reasonOnFail: String
    ) -> StageResultStatus {
        let status: StageResultStatus = findings.isEmpty ? .pass : .fail
        let reason = findings.isEmpty ? reasonOnPass : reasonOnFail

        let previous = runs[idx].latestReport
        let syntax = stage == .syntaxGate ? findings : (previous?.syntaxFindings ?? [])
        let motion = stage == .motionSemanticGate ? findings : (previous?.motionFindings ?? [])
        let runtime = stage == .runtimeGate ? findings : (previous?.runtimeFindings ?? [])

        let report = reportBuilder.build(
            revisionID: runs[idx].latestRevisionID ?? UUID(),
            syntaxFindings: syntax,
            motionFindings: motion,
            runtimeFindings: runtime
        )

        runs[idx].reports.append(report)
        markStage(stage, status: status, reason: reason, run: &runs[idx])
        appendRevision(for: stage, status: status, reason: reason, run: &runs[idx])
        runs[idx].currentStage = findings.isEmpty ? stage : .issueResolutionLoop
        persist(runs[idx])
        return status
    }

    private func appendRevision(
        for stage: PipelineStage,
        status: StageResultStatus,
        reason: String,
        run: inout PipelineRun
    ) {
        let revision = ArtifactRevision(
            id: UUID(),
            parentRevisionID: run.latestRevisionID,
            sourceArtifactID: run.sourceArtifact.id,
            stage: stage,
            createdAt: .now,
            actor: "user",
            diffSummary: diffService.makeDiffSummary(previous: run.revisions.last, nextStage: stage),
            rollbackPointer: run.latestPassingRevisionID,
            stageResult: status
        )
        run.revisions.append(revision)
    }

    private func markStage(
        _ stage: PipelineStage,
        status: StageResultStatus,
        reason: String,
        run: inout PipelineRun
    ) {
        if let index = run.stageResults.firstIndex(where: { $0.stage == stage }) {
            run.stageResults[index].status = status
            run.stageResults[index].reason = reason
            run.stageResults[index].updatedAt = .now
        } else {
            run.stageResults.append(StageResultRecord(
                id: UUID(),
                stage: stage,
                status: status,
                reason: reason,
                updatedAt: .now
            ))
        }
    }

    private func incrementRetry(_ stage: PipelineStage, run: inout PipelineRun) {
        if let index = run.retries.firstIndex(where: { $0.stage == stage }) {
            run.retries[index].attempts += 1
        } else {
            run.retries.append(StageRetryRecord(id: UUID(), stage: stage, attempts: 1))
        }
    }

    private func resetRetryBudgets(run: inout PipelineRun) {
        run.retries.removeAll()
    }

    private func consumesRetryBudget(for stage: PipelineStage, run: PipelineRun) -> Bool {
        if stage == .issueResolutionLoop {
            return true
        }
        return run.status(for: stage) != .pass
    }

    private func effectiveDraftURL(for run: PipelineRun, context: PipelineRunContext) -> URL? {
        if let draftPath = run.drafts.last?.lottieJSONRef {
            return URL(fileURLWithPath: draftPath)
        }
        if run.sourceArtifact.sourceType == .lottieJSON {
            return context.sourceURL
        }
        return nil
    }

    private func context(for run: PipelineRun) -> PipelineRunContext? {
        let sourceURL = URL(fileURLWithPath: run.sourceArtifact.payloadRef)
        let runDirectory = runDirectory(for: run.id)
        guard sourceURL.isFileURL else { return nil }
        return PipelineRunContext(runID: run.id, sourceURL: sourceURL, runDirectory: runDirectory)
    }

    private func defaultExtension(for sourceType: SourceType) -> String {
        switch sourceType {
        case .lottieJSON:
            return "json"
        case .svg:
            return "svg"
        case .promptSpec:
            return "txt"
        }
    }

    private func runDirectory(for runID: UUID) -> URL {
        let dir = pipelineRoot
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func loadPersistedRuns() {
        if let data = try? Data(contentsOf: indexURL),
           let entries = try? JSONDecoder().decode([PipelineIndexEntry].self, from: data) {
            itemIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.itemID, $0.runID) })
        }

        let runsRoot = pipelineRoot.appendingPathComponent("runs", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: runsRoot, includingPropertiesForKeys: nil) else {
            return
        }

        runs = entries.compactMap { url in
            let runURL = url.appendingPathComponent("run.json")
            guard let data = try? Data(contentsOf: runURL) else { return nil }
            return try? JSONDecoder().decode(PipelineRun.self, from: data)
        }
    }

    private func persist(_ run: PipelineRun) {
        let runDir = runDirectory(for: run.id)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let runFile = runDir.appendingPathComponent("run.json")
        if let data = try? encoder.encode(run) {
            try? data.write(to: runFile, options: .atomic)
        }

        if let data = try? encoder.encode(run.sourceArtifact) {
            try? data.write(to: runDir.appendingPathComponent("source.json"), options: .atomic)
        }

        if let data = try? encoder.encode(run.revisions) {
            try? data.write(to: runDir.appendingPathComponent("revisions.json"), options: .atomic)
        }

        if let data = try? encoder.encode(run.gateResult) {
            try? data.write(to: runDir.appendingPathComponent("gate-results.json"), options: .atomic)
        }

        if let report = run.latestReport,
           let data = try? encoder.encode(report) {
            let file = "qa-report-\(report.revisionID.uuidString).json"
            try? data.write(to: runDir.appendingPathComponent(file), options: .atomic)
        }

        if let candidate = run.readyCandidate,
           let data = try? encoder.encode(candidate) {
            try? data.write(to: runDir.appendingPathComponent("candidate.json"), options: .atomic)
        }

        if let ready = run.readyLottie,
           let data = try? encoder.encode(ready) {
            try? data.write(to: runDir.appendingPathComponent("ready-lottie.json"), options: .atomic)
        }
    }

    private func persistIndex() {
        let entries = itemIndex.map { PipelineIndexEntry(itemID: $0.key, runID: $0.value) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    private func migrateLegacyIfNeeded(animationStore: AnimationStore) async {
        var changed = false
        for item in animationStore.animations {
            if itemIndex[item.id] == nil {
                _ = await ensureRun(for: item, animationStore: animationStore)
                changed = true
            }
        }
        if changed {
            persistIndex()
        }
    }
}
