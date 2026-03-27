import SwiftUI

// ══════════════════════════════════════════════════════
//  FunctionButtonSection.swift — Features · Home · Components
// ══════════════════════════════════════════════════════

struct FunctionButtonSection: View {
    @ObservedObject var viewModel: HomeViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                PrimaryButton(label: "Funcion_1") {
                    viewModel.executeFunction(.function1)
                }
                PrimaryButton(label: "Funcion_2") {
                    viewModel.executeFunction(.function2)
                }
            }

            PrimaryButton(label: "Funcion_3") {
                viewModel.executeFunction(.function3)
            }
            .frame(width: 155)
        }
        .padding(.horizontal, 18)
    }
}
