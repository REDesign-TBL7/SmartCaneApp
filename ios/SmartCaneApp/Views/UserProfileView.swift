/*
 File: UserProfileView.swift
 Purpose:
 This file shows the single local user's profile, saved locations, and trip stats.

 Data source:
 Everything here comes from local persisted data on this phone.
 There is no account system and there is no demo content on first launch.
*/

import SwiftUI

struct UserProfileView: View {
    @EnvironmentObject private var connectionManager: CaneConnectionManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var profileManager: ProfileManager
    @State private var draftName = ""

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

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    profileHeader
                    statsSection
                    favoritesSection
                    recentPlacesSection
                    deviceSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftName = profileManager.currentProfile.name
        }
        .onDisappear {
            saveDraftNameIfNeeded()
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.84, green: 0.90, blue: 0.92),
                                Color.white
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 68, height: 68)

                Text(profileInitials)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color(red: 0.18, green: 0.29, blue: 0.33))
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Enter your name", text: $draftName)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .onSubmit {
                        saveDraftNameIfNeeded()
                    }
                    .accessibilityLabel("User name")
                    .accessibilityHint("Enter the name stored locally on this phone.")

                Text("Saved on this iPhone")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text("Saved locations and trip stats stay on this phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .accessibilityLabel("Profile")
        .accessibilityHint("Shows the saved user name and summary details.")
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Stats")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                statCard(title: "Trips", value: locationManager.totalTripsText)
                statCard(title: "Distance", value: locationManager.totalDistanceText)
                statCard(title: "Saved Places", value: locationManager.favoriteCountText)
            }
        }
    }

    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Saved Locations")

            if locationManager.favoritePlaces.isEmpty {
                emptyStateCard("No saved locations yet. Use the star in search results to save a place.")
            } else {
                ForEach(locationManager.favoritePlaces) { place in
                    HStack(spacing: 14) {
                        Image(systemName: place.systemImageName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.18, green: 0.34, blue: 0.37))
                            .frame(width: 22)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.displayTitle)
                                .font(.subheadline.weight(.semibold))
                            Text(place.displaySubtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Menu {
                            ForEach(locationManager.commonFavoriteLabels, id: \.self) { label in
                                Button(label) {
                                    locationManager.updateFavoritePlaceLabel(place, label: label == "Other" ? nil : label)
                                }
                            }

                            Button("Remove saved location", role: .destructive) {
                                locationManager.removeFavoritePlace(place)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Color(red: 0.18, green: 0.34, blue: 0.37))
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Edit \(place.displayTitle)")
                        .accessibilityHint("Change label or remove this saved location.")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Saved location \(place.displayTitle), \(place.displaySubtitle)")
                }
            }
        }
    }

    private var recentPlacesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Previous Trips")

            if locationManager.recentRoutes.isEmpty {
                emptyStateCard("No previous trips yet. Start navigation to build your trip history.")
            } else {
                ForEach(locationManager.recentRoutes) { route in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(route.destinationName)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(route.dayLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(route.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Previous trip to \(route.destinationName), \(route.summary), \(route.dayLabel)")
                }
            }
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Cane Device")

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(connectionManager.pairedDevice?.deviceName ?? "No paired cane")
                        .font(.subheadline.weight(.semibold))

                    if let pairedDevice = connectionManager.pairedDevice {
                        Text("Runtime endpoint \(pairedDevice.host):\(pairedDevice.port)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(connectionManager.caneState.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(red: 0.29, green: 0.35, blue: 0.38))
    }

    private func statCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }

    private func emptyStateCard(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
    }

    private var profileInitials: String {
        let components = (profileManager.currentProfile.name.isEmpty ? "SC" : profileManager.currentProfile.name)
            .split(separator: " ")
            .prefix(2)

        let letters = components.compactMap { component in
            component.first.map(String.init)
        }

        let result = letters.joined()
        return result.isEmpty ? "SC" : result.uppercased()
    }

    private func saveDraftNameIfNeeded() {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != profileManager.currentProfile.name {
            profileManager.updateName(trimmedName)
            draftName = trimmedName
        }
    }
}

struct UserProfileView_Previews: PreviewProvider {
    static var previews: some View {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        let visionManager = VisionManager(connectionManager: connectionManager)
        let fusionManager = GuidanceFusionManager(connectionManager: connectionManager, visionManager: visionManager)

        return UserProfileView()
            .environmentObject(connectionManager)
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
            .environmentObject(profileManager)
    }
}
