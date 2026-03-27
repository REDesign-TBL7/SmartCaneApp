/*
 File: CVModelView.swift
 Purpose:
 This file contains the placeholder UI for the future on-device
 Vision-Language Model (VLM) that will perform real-time scene understanding.
*/

import SwiftUI

struct CVModelView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.95, blue: 0.92),
                    Color(red: 0.90, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text("On-device VLM")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("Future real-time scene understanding placeholder")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(Color.black)
                        .frame(height: 300)
                        .overlay(
                            Text("Live scene stream placeholder")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                        )
                        .accessibilityHidden(true)

                    Text("Placeholder")
                        .font(.headline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(18)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Mock scene summary")
                        .font(.headline.weight(.semibold))
                    Text("Scene: outdoor walkway")
                        .font(.body)
                    Text("Objects: person, railing, staircase")
                        .font(.body)
                    Text("Suggested cue: keep slightly left")
                        .font(.body)
                    Text("TODO: Replace this placeholder with real on-device VLM output and streaming scene understanding.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("On-device Vision Language Model placeholder screen")
        .accessibilityHint("Shows the future real-time scene understanding placeholder interface.")
    }
}

struct CVModelView_Previews: PreviewProvider {
    static var previews: some View {
        CVModelView()
    }
}
