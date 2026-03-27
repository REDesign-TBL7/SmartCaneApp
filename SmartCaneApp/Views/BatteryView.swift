/*
 File: BatteryView.swift
 Purpose:
 This file shows a cleaner, more premium battery presentation for the smart cane.
*/

import SwiftUI

struct BatteryView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.92, green: 0.95, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text("Battery")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 18) {
                        Image(systemName: batteryIconName)
                            .font(.system(size: 64, weight: .semibold))
                            .foregroundStyle(batteryColor)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(connectionManager.caneState.batteryPercentage)%")
                                .font(.system(size: 56, weight: .bold, design: .rounded))

                            Text("Current cane battery")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.75))
                            Capsule()
                                .fill(batteryColor.gradient)
                                .frame(width: geometry.size.width * batteryFillWidth)
                        }
                    }
                    .frame(height: 18)

                    HStack(spacing: 12) {
                        detailPill(title: "Status", value: batteryStatusText)
                        detailPill(title: "Speech alert", value: connectionManager.caneState.batteryPercentage < 20 ? "Needed" : "Quiet")
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cane battery: \(connectionManager.caneState.batteryPercentage) percent")
        .accessibilityHint("Shows a large battery readout and battery status details.")
    }

    private var batteryColor: Color {
        let battery = connectionManager.caneState.batteryPercentage

        if battery > 50 {
            return .green
        } else if battery >= 20 {
            return .orange
        } else {
            return .red
        }
    }

    private var batteryFillWidth: CGFloat {
        CGFloat(connectionManager.caneState.batteryPercentage) / 100.0
    }

    private var batteryIconName: String {
        let battery = connectionManager.caneState.batteryPercentage

        if battery > 75 {
            return "battery.100"
        } else if battery > 50 {
            return "battery.75"
        } else if battery > 25 {
            return "battery.50"
        } else {
            return "battery.25"
        }
    }

    private var batteryStatusText: String {
        let battery = connectionManager.caneState.batteryPercentage

        if battery > 50 {
            return "Strong"
        } else if battery >= 20 {
            return "Moderate"
        } else {
            return "Low"
        }
    }

    private func detailPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.72), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct BatteryView_Previews: PreviewProvider {
    static var previews: some View {
        BatteryView()
            .environmentObject(CaneConnectionManager())
    }
}
