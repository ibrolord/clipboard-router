import ClipboardRouterCore
import SwiftUI

enum AutomationRunAccessibility {
    static let unresolvedCount = "uiAcceptance.flow.ledger.unresolvedCount"
    static let pauseAll = "uiAcceptance.flow.ledger.pauseAll"

    static func pauseFlow(_ flowID: UUID) -> String {
        "uiAcceptance.flow.ledger.pauseFlow.\(uuid(flowID))"
    }

    static func row(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.row.\(uuid(runID))"
    }

    static func review(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.review.\(uuid(runID))"
    }

    static func retry(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.retry.\(uuid(runID))"
    }

    static func reconcile(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.reconcile.\(uuid(runID))"
    }

    static func reconcileSucceeded(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.reconcileSucceeded.\(uuid(runID))"
    }

    static func reconcileCancelled(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.reconcileCancelled.\(uuid(runID))"
    }

    static func cancel(_ runID: UUID) -> String {
        "uiAcceptance.flow.ledger.cancel.\(uuid(runID))"
    }

    static func rowValue(_ run: AutomationRunRecord, flowName: String) -> String {
        [
            "flow=\(component(flowName))",
            "status=\(run.status.rawValue)",
            "completed=\(run.completedStepCount)",
            "total=\(run.steps.count)",
            "retry=\(run.canRetry)",
            "failure=\(run.failureCode?.rawValue ?? "none")",
        ].joined(separator: "|")
    }

    static func component(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func uuid(_ id: UUID) -> String { id.uuidString.lowercased() }
}

struct AutomationRunLedgerSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.unresolvedAutomationRunCount > 0 {
            Section {
                Label(
                    "\(model.unresolvedAutomationRunCount) automation run\(model.unresolvedAutomationRunCount == 1 ? "" : "s") need your attention.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier(AutomationRunAccessibility.unresolvedCount)
                .accessibilityValue("count=\(model.unresolvedAutomationRunCount)")
            }
        }
        Section("Run safety") {
            Toggle(
                "Pause all automation execution",
                isOn: Binding(
                    get: { model.automationRunSnapshot.controls.isPaused },
                    set: { paused in model.setAllAutomationRunsPaused(paused) }
                )
            )
            .accessibilityIdentifier(AutomationRunAccessibility.pauseAll)
            .accessibilityValue("paused=\(model.automationRunSnapshot.controls.isPaused)")
            Text("Pausing stops future steps. It does not undo completed work or claim that an in-progress external action was rolled back.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.clipFlows.isEmpty {
                DisclosureGroup("Per-action kill switches") {
                    ForEach(model.clipFlows) { flow in
                        Toggle(
                            flow.name,
                            isOn: Binding(
                                get: {
                                    model.automationRunSnapshot.controls.pausedFlowIDs
                                        .contains(flow.id)
                                },
                                set: { model.setFlowExecutionPaused(flow.id, paused: $0) }
                            )
                        )
                        .accessibilityIdentifier(AutomationRunAccessibility.pauseFlow(flow.id))
                        .accessibilityValue(
                            "paused=\(model.automationRunSnapshot.controls.pausedFlowIDs.contains(flow.id))"
                        )
                    }
                }
            }
        }

        Section("Recent automation runs") {
            if model.automationRunSnapshot.runs.isEmpty {
                Text("No durable runs yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.automationRunSnapshot.runs.prefix(12)) { run in
                    AutomationRunRow(model: model, run: run)
                }
            }
        }
    }
}

private struct AutomationRunRow: View {
    @ObservedObject var model: AppModel
    let run: AutomationRunRecord

    private var flowName: String {
        model.clipFlows.first(where: { $0.id == run.flowID })?.name ?? "Changed or removed action"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(flowName)
                Text("\(statusTitle) · \(run.completedStepCount) of \(run.steps.count) execution units completed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if run.status == .uncertain {
                    Text("Clipboard Router cannot prove whether the last external step completed. Check the destination before deciding.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            controls
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AutomationRunAccessibility.row(run.id))
        .accessibilityValue(AutomationRunAccessibility.rowValue(run, flowName: flowName))
    }

    @ViewBuilder private var controls: some View {
        switch run.status {
        case .needsReview:
            Button("Review") { model.reviewAutomationRun(run.id) }
                .accessibilityIdentifier(AutomationRunAccessibility.review(run.id))
        case .failed where run.canRetry:
            Button("Review Retry") { model.reviewAutomationRun(run.id) }
                .accessibilityIdentifier(AutomationRunAccessibility.retry(run.id))
        case .uncertain:
            Menu("Reconcile") {
                Button("I confirmed the step completed") {
                    model.reconcileAutomationRun(run.id, markSucceeded: true)
                }
                .accessibilityIdentifier(AutomationRunAccessibility.reconcileSucceeded(run.id))
                Button("Stop remaining steps", role: .destructive) {
                    model.reconcileAutomationRun(run.id, markSucceeded: false)
                }
                .accessibilityIdentifier(AutomationRunAccessibility.reconcileCancelled(run.id))
            }
            .accessibilityIdentifier(AutomationRunAccessibility.reconcile(run.id))
        case .planned, .running:
            Button("Cancel", role: .destructive) { model.cancelAutomationRun(run.id) }
                .accessibilityIdentifier(AutomationRunAccessibility.cancel(run.id))
        case .succeeded, .failed, .cancelled:
            EmptyView()
        }
    }

    private var statusTitle: String {
        switch run.status {
        case .planned: "Planned"
        case .running: "Running"
        case .needsReview: "Needs review"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .uncertain: "Outcome uncertain"
        case .cancelled: "Cancelled"
        }
    }

    private var symbol: String {
        switch run.status {
        case .planned, .needsReview: "clock.badge.exclamationmark"
        case .running: "gearshape.2"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .uncertain: "questionmark.diamond.fill"
        case .cancelled: "stop.circle"
        }
    }

    private var color: Color {
        switch run.status {
        case .succeeded: .green
        case .failed: .red
        case .uncertain, .needsReview: .orange
        case .planned, .running, .cancelled: .secondary
        }
    }
}
