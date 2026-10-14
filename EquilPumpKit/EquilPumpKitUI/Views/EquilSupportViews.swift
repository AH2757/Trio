import EquilPumpKit
import LoopKitUI
import SwiftUI

/// 简易加载指示器（对照 MedtrumKit `ActivityIndicator`）。
struct EquilActivityIndicator: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle())
    }
}

/// 泵示意图。Equil 无自定义位图资源，统一用 SF Symbol 占位。
struct EquilPumpImage: View {
    var height: CGFloat = 120

    var body: some View {
        HStack {
            Spacer()
            Image(systemName: "drop.fill")
                .resizable()
                .scaledToFit()
                .foregroundColor(.accentColor)
                .padding(.horizontal)
                .frame(height: height)
            Spacer()
        }
        .accessibilityHidden(true)
    }
}

/// 删除驱动确认弹窗（对照 MedtrumKit `removePumpManagerActionSheet`）。
func removeEquilPumpManagerActionSheet(deleteAction: @escaping () -> Void) -> ActionSheet {
    ActionSheet(
        title: Text("Remove Pump", comment: "Title for pump deletion action sheet"),
        message: Text(
            "Are you sure you want to stop using the Equil patch pump? The pump will keep delivering its local basal rate after removal.",
            comment: "Message for pump deletion action sheet"
        ),
        buttons: [
            .destructive(Text("Delete Pump", comment: "Button text to confirm pump deletion")) {
                deleteAction()
            },
            .cancel()
        ]
    )
}