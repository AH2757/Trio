import EquilPumpKit
import LoopKit
import LoopKitUI
import SwiftUI

/// 泵设置页，对照 MedtrumKit `MedtrumKitSettings`。
struct EquilKitSettingsView: View {
    @ObservedObject var viewModel: EquilKitSettingsViewModel

    @Environment(\.dismissAction) private var dismiss
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.insulinTintColor) private var insulinTintColor

    var body: some View {
        List {
            Section {
                VStack {
                    EquilPumpImage(height: 90)
                    HStack(alignment: .top) {
                        deliveryStatus
                        Spacer()
                        reservoirStatus
                    }
                    .padding(.bottom, 5)
                }
            }

            Section {
                Button(action: { viewModel.suspendResumeButtonPressed() }) {
                    HStack {
                        Text(viewModel.isSuspended
                            ? String(localized: "Resume Insulin Delivery", comment: "Resume pump")
                            : String(localized: "Suspend Insulin Delivery", comment: "Suspend pump"))
                        Spacer()
                        if viewModel.isUpdatingSuspend {
                            EquilActivityIndicator()
                        }
                    }
                }
                .disabled(isBusy)

                if viewModel.basalType == .tempBasal {
                    Button(action: { viewModel.stopTempBasal() }) {
                        HStack {
                            Text("Stop Temp Basal", comment: "Stop temp basal")
                            Spacer()
                            if viewModel.isUpdatingTempBasal {
                                EquilActivityIndicator()
                            }
                        }
                    }
                    .disabled(isBusy)
                }

                Button(action: { viewModel.syncData() }) {
                    HStack {
                        Text("Sync Pump Data", comment: "Sync pump data")
                        Spacer()
                        if viewModel.isUpdatingPumpState {
                            EquilActivityIndicator()
                        }
                    }
                }
                .disabled(isBusy)

                if viewModel.basalType != .tempBasal {
                    Button(action: { viewModel.toManualTempBasal() }) {
                        HStack {
                            Text("Manual Temp Basal", comment: "Manual temp basal")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: UIFont.systemFontSize, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Text("Pump State", comment: "Text for pump state")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.runModeText)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Last Sync", comment: "Text for last sync")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.lastSync == .distantPast
                        ? "–"
                        : viewModel.dateFormatter.string(from: viewModel.lastSync))
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Battery", comment: "Text for battery level")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.batteryText)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Status", comment: "Text for connection status")
                        .foregroundColor(.primary)
                    Spacer()
                    HStack(spacing: 10) {
                        Text(viewModel.isConnected
                            ? String(localized: "Connected", comment: "label for connected")
                            : String(localized: "Disconnected", comment: "label for disconnected"))
                        Circle()
                            .fill(viewModel.isConnected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                    }
                }
            }

            Section {
                HStack {
                    Text("Insulin Type", comment: "Text for selecting insulin type")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.insulinType.brandName)
                        .foregroundColor(.secondary)
                        .padding(.trailing, 3)
                    Image(systemName: "chevron.right")
                        .font(.system(size: UIFont.systemFontSize, weight: .medium))
                        .opacity(0.3)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.toInsulinType()
                }
            } header: {
                Text("Configuration", comment: "Configuration section")
            }

            Section {
                HStack {
                    Text("Serial number", comment: "Text for serial number")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.serialNumber.isEmpty ? "–" : viewModel.serialNumber)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Firmware", comment: "Text for firmware version")
                        .foregroundColor(.primary)
                    Spacer()
                    Text(viewModel.firmwareVersion ?? "–")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Information", comment: "The title for pump information")
            }

            Section {
                Button(action: {
                    viewModel.showingDeleteConfirmation = true
                }) {
                    Text("Delete Pump", comment: "Label for pump deletion button")
                        .foregroundColor(guidanceColors.critical)
                }
                .actionSheet(isPresented: $viewModel.showingDeleteConfirmation) {
                    removeEquilPumpManagerActionSheet(deleteAction: viewModel.stopUsingEquil)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationBarItems(trailing: doneButton)
    }

    private var isBusy: Bool {
        viewModel.isUpdatingPumpState || viewModel.isUpdatingSuspend || viewModel.isUpdatingTempBasal
    }

    private var doneButton: some View {
        Button(String(localized: "Done", comment: "Button for closing settings"), action: {
            dismiss()
        })
    }

    private var reservoirStatus: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("Insulin Remaining", comment: "Header for insulin remaining")
                .foregroundColor(Color(UIColor.secondaryLabel))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(viewModel.reservoirText(for: viewModel.reservoirLevel))
                    .font(.system(size: 28))
                    .fontWeight(.heavy)
                    .fixedSize()
                Text("U", comment: "Insulin unit")
                    .foregroundStyle(.secondary)
            }
            .foregroundColor(reservoirColor)
        }
    }

    private var deliveryStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(viewModel.basalType == .tempBasal
                ? String(localized: "Temp Basal", comment: "Title of insulin delivery section")
                : String(localized: "Scheduled Basal", comment: "Title of insulin delivery section"))
                .foregroundColor(Color(UIColor.secondaryLabel))

            if viewModel.isSuspended {
                HStack(alignment: .center) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 34))
                        .fixedSize()
                        .foregroundColor(guidanceColors.warning)
                    Text("Insulin\nSuspended", comment: "Text shown when insulin suspended")
                        .fontWeight(.bold)
                        .fixedSize()
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(viewModel.basalRate)
                        .font(.system(size: 28))
                        .fontWeight(.heavy)
                        .fixedSize()
                    Text("U/hr", comment: "Units for showing basal rate")
                        .foregroundColor(.secondary)
                    if let remaining = viewModel.tempBasalRemaining {
                        Text(remaining)
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private var reservoirColor: Color {
        let level = viewModel.reservoirLevel
        if level > viewModel.maxReservoirLevel * 0.1 {
            return insulinTintColor
        }
        if level > 0 {
            return guidanceColors.warning
        }
        return guidanceColors.critical
    }
}