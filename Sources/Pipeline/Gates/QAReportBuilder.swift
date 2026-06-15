import Foundation

struct QAReportBuilder {
    func build(
        revisionID: UUID,
        syntaxFindings: [QAFinding],
        motionFindings: [QAFinding],
        runtimeFindings: [QAFinding]
    ) -> QAReport {
        let all = syntaxFindings + motionFindings + runtimeFindings
        let highest = all.max(by: { $0.severity.sortRank < $1.severity.sortRank })?.severity
        return QAReport(
            id: UUID(),
            revisionID: revisionID,
            syntaxFindings: syntaxFindings,
            motionFindings: motionFindings,
            runtimeFindings: runtimeFindings,
            highestSeverity: highest
        )
    }
}
