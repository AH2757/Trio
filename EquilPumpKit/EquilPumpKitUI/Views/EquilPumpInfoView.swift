import LoopKit
import LoopKitUI
import SwiftUI

/// 泵信息录入页：泵号 + 配对密码 + 胰岛素类型。
struct EquilPumpInfoView: View {
    @ObservedObject var viewModel: EquilPumpInfoViewModel

    var body: some View {
        VStack {
            List {
                Section {
                    EquilPumpImage()
                    HStack {
                        Text("Serial number", comment: "Label for pump serial number")
                            .foregroundColor(.primary)
                        Spacer()
                        TextField("D02563", text: $viewModel.serialNumber)
                            .multilineTextAlignment(.trailing)
                            .autocapitalization(.allCharacters)
                            .disableAutocorrection(true)
                    }
                    HStack {
                        Text("Pairing password", comment: "Label for pump pairing password")
                            .foregroundColor(.primary)
                        Spacer()
                        TextField("123456", text: $viewModel.password)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                } footer: {
                    Text(
                        "The serial number is printed on the pump. The pairing password is shown on the pump's display.",
                        comment: "Footer for pump serial number and pairing password"
                    )
                }

                Section {
                    Text("Select the type of insulin that you will be using", comment: "Title for insulin type confirmation page")
                    ScrollView {
                        InsulinTypeChooser(insulinType: $viewModel.insulinType, supportedInsulinTypes: viewModel.allowedInsulinTypes)
                            .padding(.horizontal)
                    }
                }
            }

            Spacer()

            if !viewModel.errorMessage.isEmpty {
                Text(viewModel.errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Button(action: { viewModel.saveAndContinue() }) {
                Text("Continue", comment: "Continue button")
            }
            .disabled(!viewModel.canContinue)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
    }
}