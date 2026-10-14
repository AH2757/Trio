import LoopKit
import LoopKitUI
import SwiftUI

/// 胰岛素类型选择页（设置页内编辑用），对照 MedtrumKit `InsulinTypeSelector`。
struct EquilInsulinTypeView: View {
    @State private var insulinType: InsulinType?

    private let supportedInsulinTypes: [InsulinType]
    private let didConfirm: (InsulinType) -> Void

    init(
        initialValue: InsulinType,
        supportedInsulinTypes: [InsulinType],
        didConfirm: @escaping (InsulinType) -> Void
    ) {
        _insulinType = State(initialValue: initialValue)
        self.supportedInsulinTypes = supportedInsulinTypes
        self.didConfirm = didConfirm
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section {
                    Text("Select the type of insulin that you will be using", comment: "Title text for insulin type confirmation page")
                    ScrollView {
                        InsulinTypeChooser(insulinType: $insulinType, supportedInsulinTypes: supportedInsulinTypes)
                            .padding(.horizontal)
                    }
                }
            }

            Spacer()

            Button(action: {
                if let insulinType = insulinType {
                    didConfirm(insulinType)
                }
            }) {
                Text("Save", comment: "Save button")
            }
            .disabled(insulinType == nil)
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .edgesIgnoringSafeArea(.bottom)
    }
}