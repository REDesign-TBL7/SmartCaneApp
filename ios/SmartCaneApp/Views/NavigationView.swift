/*
 File: NavigationView.swift
 Purpose:
 This screen is the destination picker for the blind-first app flow.

 Design notes:
 The screen is intentionally simple:
 - search field at the top
 - live search results directly below it
 - favourites and recent destinations as large plain buttons
 - no visual map, so VoiceOver focus order stays predictable
*/

import SwiftUI

struct NavigationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var locationManager: LocationManager
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.95, blue: 0.92),
                    Color(red: 0.91, green: 0.94, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    topControls

                    if showSearchSuggestions {
                        searchResultsPanel
                    } else if isSearchFieldFocused && !trimmedSearchText.isEmpty {
                        helperCard("Search results will appear here as you type.")
                    }

                    if locationManager.hasActiveNavigation {
                        currentDestinationButton
                    }

                    if !showSearchSuggestions {
                        savedPlacesSection
                        recentPlacesSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            locationManager.prepareForSearchEntry()
        }
    }

    private var topControls: some View {
        HStack(spacing: 10) {
            backButton
            searchPanel
        }
    }

    private var searchPanel: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search destination", text: $locationManager.searchText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .font(.subheadline)
                .focused($isSearchFieldFocused)
                .accessibilityLabel("Search destination")
                .accessibilityHint("Type a destination name. Results will appear below.")

            if !trimmedSearchText.isEmpty {
                Button {
                    locationManager.prepareForSearchEntry()
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clears the current search text.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 52)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(locationManager.searchResults) { result in
                HStack(spacing: 12) {
                    Button {
                        Task {
                            let didConfirm = await locationManager.confirmSearchResult(result)
                            if didConfirm {
                                dismiss()
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(red: 0.12, green: 0.18, blue: 0.22))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !result.subtitle.isEmpty {
                                Text(result.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(result.displayName)
                    .accessibilityHint("Starts navigation to this destination.")

                    Button {
                        Task {
                            await locationManager.toggleSearchResultFavorite(result)
                        }
                    } label: {
                        Image(systemName: favoriteIconName(for: result))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(red: 0.89, green: 0.71, blue: 0.22))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(favoriteIconName(for: result) == "star.fill" ? "Remove \(result.displayName) from favourites" : "Save \(result.displayName) to favourites")
                    .accessibilityHint("Toggles whether this destination is saved.")
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private var currentDestinationButton: some View {
        Button {
            locationManager.clearNavigation()
        } label: {
            placeRow(
                title: locationManager.navigationStatusValue,
                subtitle: "Double-tap to clear the current destination.",
                systemImage: "location.fill"
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current destination \(locationManager.navigationStatusValue)")
        .accessibilityHint("Double-tap to clear the current destination.")
    }

    private var savedPlacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if locationManager.favoritePlaces.isEmpty {
                helperCard("No saved places yet. Use the star next to a search result to save one.")
            } else {
                ForEach(locationManager.favoritePlaces) { place in
                    Button {
                        locationManager.selectFavorite(place)
                        dismiss()
                    } label: {
                        placeRow(
                            title: place.name,
                            subtitle: place.subtitle,
                            systemImage: place.systemImageName
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Saved place \(place.name)")
                    .accessibilityHint("Starts navigation to this saved place.")
                }
            }
        }
    }

    private var recentPlacesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if locationManager.recentRoutes.isEmpty {
                helperCard("No recent destinations yet.")
            } else {
                ForEach(locationManager.recentRoutes.prefix(5)) { route in
                    Button {
                        locationManager.selectRecent(route)
                        dismiss()
                    } label: {
                        placeRow(
                            title: route.destinationName,
                            subtitle: route.summary,
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Recent destination \(route.destinationName)")
                    .accessibilityHint("Starts navigation to this recent destination.")
                }
            }
        }
    }

    private func placeRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.34, blue: 0.37))
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.12, green: 0.18, blue: 0.22))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func helperCard(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(red: 0.15, green: 0.20, blue: 0.23))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to the home screen.")
    }

    private var trimmedSearchText: String {
        locationManager.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showSearchSuggestions: Bool {
        isSearchFieldFocused && !locationManager.searchResults.isEmpty
    }

    private func favoriteIconName(for result: LocationSearchResult) -> String {
        let displayName = result.displayName.lowercased()
        let isSaved = locationManager.favoritePlaces.contains { place in
            let savedDisplayName = "\(place.name), \(place.subtitle)".lowercased()
            return savedDisplayName == displayName || place.name.lowercased() == result.title.lowercased()
        }

        return isSaved ? "star.fill" : "star"
    }
}

struct NavigationView_Previews: PreviewProvider {
    static var previews: some View {
        let profileManager = ProfileManager()
        let connectionManager = CaneConnectionManager()
        let visionManager = VisionManager(connectionManager: connectionManager)
        let fusionManager = GuidanceFusionManager(connectionManager: connectionManager, visionManager: visionManager)

        return NavigationView()
            .environmentObject(LocationManager(profileManager: profileManager, connectionManager: connectionManager, fusionManager: fusionManager))
    }
}
