import Foundation

struct SourceArtifact: Identifiable, Codable {
    let id: UUID
    let sourceType: SourceType
    let payloadRef: String
    let metadata: [String: String]
}

struct DraftArtifact: Identifiable, Codable {
    let id: UUID
    let revisionID: UUID
    let lottieJSONRef: String
    let provenance: [String: String]
}

struct QAFinding: Identifiable, Codable {
    let id: UUID
    let stage: PipelineStage
    let severity: FindingSeverity
    let code: String
    let message: String
    let fieldPath: String?
}

struct QAReport: Identifiable, Codable {
    let id: UUID
    let revisionID: UUID
    let syntaxFindings: [QAFinding]
    let motionFindings: [QAFinding]
    let runtimeFindings: [QAFinding]
    let highestSeverity: FindingSeverity?

    var allFindings: [QAFinding] {
        syntaxFindings + motionFindings + runtimeFindings
    }
}

struct GateResult: Codable {
    let syntax: StageResultStatus
    let motionSemantic: StageResultStatus
    let runtime: StageResultStatus
}

struct ReadyCandidate: Identifiable, Codable {
    let id: UUID
    let revisionID: UUID
    let gateResults: GateResult
    let riskFlags: [String]
    let approvedAt: Date?
}

struct ReadyLottie: Identifiable, Codable {
    let id: UUID
    let artifactRef: String
    let releaseManifestRef: String
    let checksum: String
}

struct ArtifactRevision: Identifiable, Codable {
    let id: UUID
    let parentRevisionID: UUID?
    let sourceArtifactID: UUID
    let stage: PipelineStage
    let createdAt: Date
    let actor: String
    let diffSummary: String?
    let rollbackPointer: UUID?
    let stageResult: StageResultStatus
}

struct StageResultRecord: Identifiable, Codable {
    let id: UUID
    let stage: PipelineStage
    var status: StageResultStatus
    var reason: String?
    var updatedAt: Date
}

struct StageRetryRecord: Identifiable, Codable {
    let id: UUID
    let stage: PipelineStage
    var attempts: Int
}

struct PipelineRun: Identifiable, Codable {
    let id: UUID
    var displayName: String
    let sourceArtifact: SourceArtifact
    var currentStage: PipelineStage
    var createdAt: Date
    var revisions: [ArtifactRevision]
    var stageResults: [StageResultRecord]
    var retries: [StageRetryRecord]
    var drafts: [DraftArtifact]
    var reports: [QAReport]
    var readyCandidate: ReadyCandidate?
    var readyLottie: ReadyLottie?

    init(id: UUID = UUID(), displayName: String, sourceArtifact: SourceArtifact, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.sourceArtifact = sourceArtifact
        self.currentStage = .sourceIntake
        self.createdAt = createdAt
        self.revisions = []
        self.stageResults = []
        self.retries = []
        self.drafts = []
        self.reports = []
        self.readyCandidate = nil
        self.readyLottie = nil
    }

    func status(for stage: PipelineStage) -> StageResultStatus {
        stageResults.first(where: { $0.stage == stage })?.status ?? .retryable
    }

    func reason(for stage: PipelineStage) -> String? {
        stageResults.first(where: { $0.stage == stage })?.reason
    }

    func retryCount(for stage: PipelineStage) -> Int {
        retries.first(where: { $0.stage == stage })?.attempts ?? 0
    }

    var latestRevisionID: UUID? {
        revisions.last?.id
    }

    var latestReport: QAReport? {
        reports.last
    }

    var gateResult: GateResult {
        GateResult(
            syntax: status(for: .syntaxGate),
            motionSemantic: status(for: .motionSemanticGate),
            runtime: status(for: .runtimeGate)
        )
    }

    var latestPassingRevisionID: UUID? {
        revisions.reversed().first(where: { $0.stageResult == .pass })?.id
    }
}

struct PipelineIndexEntry: Codable {
    let itemID: UUID
    let runID: UUID
}
