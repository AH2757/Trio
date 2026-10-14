import LoopKitUI
import SwiftUI

/// 配对校验页：向用户说明配对方式并触发一次显式配对。
struct EquilPairingView: View {
    @ObservedObject var viewModel: EquilPairingViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    EquilPumpImage()
                    Text(
                        "Keep the pump nearby. Pairing binds this phone to the pump and reads back its firmware and status.",
                        comment: "Pairing instructions for the Equil pump"
                    )
                }

                Section {
                    HStack {
                        Text("Status", comment: "Label for pairing status")
                            .foregroundColor(.primary)
                        Spacer()
                        if viewModel.isPaired {
                            Text("Paired", comment: "Pairing status when paired")
                                .foregroundColor(.green)
                        } else if viewModel.isPairing {
                            Text("Pairing…", comment: "Pairing status while pairing")
                                .foregroundColor(.secondary)
                        } else {
                            Text("Not paired", comment: "Pairing status when not paired")
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("Firmware", comment: "Label for pump firmware version")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(viewModel.firmwareVersion ?? "–")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Connection", comment: "Label for pump connection state")
                            .foregroundColor(.primary)
                        Spacer()
                        Text(viewModel.isConnected
                            ? String(localized: "Connected", comment: "Connection state connected")
                            : String(localized: "Disconnected", comment: "Connection state disconnected"))
                            .foregroundColor(viewModel.isConnected ? .green : .secondary)
                    }
                } footer: {
                    Text(
                        "The pump can be controlled by its own display at any time. This app releases the pump when idle.",
                        comment: "Footer explaining the use-and-release behaviour"
                    )
                }
            }

            Spacer()

            if let error = viewModel.error {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Button(action: { viewModel.pair() }) {
                if viewModel.isPairing {
                    EquilActivityIndicator()
                } else {
                    Text("Pair and Verify", comment: "Button text to pair and verify the pump")
                }
            }
            .disabled(viewModel.isPairing)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
    }
}