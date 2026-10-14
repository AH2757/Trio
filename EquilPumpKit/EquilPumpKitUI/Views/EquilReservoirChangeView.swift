import LoopKitUI
import SwiftUI

/// 更换储药器页：填药、插管、推杆定位。
struct EquilReservoirChangeView: View {
    @ObservedObject var viewModel: EquilReservoirChangeViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    HStack(alignment: .top) {
                        Text("1.", comment: "Reservoir change step number")
                            .foregroundStyle(.primary)
                        Text(
                            "Fill the reservoir with insulin and connect it to the pump.",
                            comment: "Reservoir change step 1"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    HStack(alignment: .top) {
                        Text("2.", comment: "Reservoir change step number")
                            .foregroundStyle(.primary)
                        Text(
                            "Connect the infusion set to the pump and prepare the infusion site.",
                            comment: "Reservoir change step 2"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    HStack(alignment: .top) {
                        Text("3.", comment: "Reservoir change step number")
                            .foregroundStyle(.primary)
                        Text(
                            "Tap Start. The pushrod rewinds and then advances until it reaches the plunger.",
                            comment: "Reservoir change step 3"
                        )
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } footer: {
                    Text(
                        "Keep the pump nearby and do not disconnect it while the pushrod is moving.",
                        comment: "Reservoir change footer warning"
                    )
                }
            }

            Spacer()

            if viewModel.isChanging {
                VStack(spacing: 8) {
                    EquilActivityIndicator()
                    Text("Positioning pushrod…", comment: "Status while the pushrod positioning loop runs")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }

            if let error = viewModel.error {
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Button(action: { viewModel.start() }) {
                if viewModel.isChanging {
                    EquilActivityIndicator()
                } else {
                    Text("Start", comment: "Button text to start the reservoir change")
                }
            }
            .disabled(viewModel.isChanging)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
    }
}