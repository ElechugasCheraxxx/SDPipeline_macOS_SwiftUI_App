import SwiftUI
import AppKit

// ══════════════════════════════════════════════════════
//  HomeView.swift
//  Features/Home/Presentation/
// ══════════════════════════════════════════════════════

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        VStack(spacing: 0) {

            HeaderSection()

            Rectangle()
                .fill(DSColors.brandPrimary)
                .frame(height: 1)

            ZStack {
                DSColors.backgroundBase
                VStack(spacing: 14) {
                    Spacer(minLength: 10)
                    LogoSection()
                    FunctionButtonSection(viewModel: viewModel)
                    Spacer(minLength: 10)
                }
            }

            // ← StatusLog reemplaza StatusBadge
            StatusLog(entries: viewModel.log)
        }
        .frame(width: 360)   // altura dinámica: crece con el log abierto
        .background(DSColors.backgroundBase)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DSColors.borderDefault, lineWidth: 1)
        )
        .shadow(color: DSColors.brandPrimary.opacity(0.2), radius: 24)
    }
}

private struct LogoSection: View {
    var body: some View {
        Group {
            if let img = NSImage(named: "Blackcompany-logo") {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(height: 72)
                    .colorMultiply(.white)
            } else {
                FallbackLogo().frame(width: 72, height: 72)
            }
        }
    }
}

private struct FallbackLogo: View {
    var body: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                WingLine(index: i)
                    .stroke(style: StrokeStyle(
                        lineWidth: CGFloat(2.8 - Double(i) * 0.5),
                        lineCap: .round))
                    .foregroundColor(.white)
            }
            Text("B")
                .font(.system(size: 40, weight: .black, design: .serif))
                .foregroundColor(.white)
                .offset(x: 10, y: -4)
        }
    }
}

private struct WingLine: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.midY + CGFloat(index) * 7
        p.move(to: CGPoint(x: rect.minX + 2, y: y))
        p.addCurve(
            to: CGPoint(x: rect.midX - 10, y: rect.maxY - 4 + CGFloat(index) * 2),
            control1: CGPoint(x: rect.width * 0.2,  y: y - 4),
            control2: CGPoint(x: rect.width * 0.38, y: rect.maxY - 8)
        )
        return p
    }
}

#Preview { HomeView() }
