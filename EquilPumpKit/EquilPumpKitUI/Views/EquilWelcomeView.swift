import LoopKitUI
import SwiftUI

/// 向导欢迎页（对照 MedtrumKit `OnboardingWelcomeView`）。
struct EquilWelcomeView: View {
    @Environment(\.dismissAction) private var dismiss

    let nextStep: () -> Void

    var body: some View {
        VStack {
            List {
                Section {
                    EquilPumpImage()
                    Text(
                        "You will first set the pump serial number and pairing password, then pair and verify the pump before filling the reservoir.",
                        comment: "Welcome text for the Equil pump onboarding"
                    )
                }
            }
            Spacer()

            Button(action: { nextStep() }) {
                Text("Continue", comment: "Continue button")
            }
            .buttonStyle(ActionButtonStyle())
            .padding([.bottom, .horizontal])
        }
        .listStyle(InsetGroupedListStyle())
        .edgesIgnoringSafeArea(.bottom)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(String(localized: "Cancel", comment: "Cancel button title"), action: {
                    self.dismiss()
                })
            }
        }
    }
}