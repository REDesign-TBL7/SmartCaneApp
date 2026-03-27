/*
 File: ProfileManager.swift
 Purpose:
 This file manages one locally stored user profile for the app.

 Storage note:
 The profile is saved into UserDefaults so favourites, saved locations, and
 trip stats remain on the phone between app launches.
*/

import Foundation

@MainActor
final class ProfileManager: ObservableObject {
    @Published private(set) var currentProfile: UserProfile

    private let storageKey = "smart_cane_single_user_profile"

    init() {
        if let storedProfile = Self.loadProfile(storageKey: storageKey) {
            currentProfile = storedProfile
        } else {
            currentProfile = UserProfile()
            saveProfile()
        }
    }

    func updateName(_ name: String) {
        updateCurrentProfile { profile in
            profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func updateFavoritePlaces(_ favoritePlaces: [SavedPlace]) {
        updateCurrentProfile { profile in
            profile.favoritePlaces = favoritePlaces
        }
    }

    func updateRecentRoutes(_ recentRoutes: [NavigationHistoryItem]) {
        updateCurrentProfile { profile in
            profile.recentRoutes = recentRoutes
        }
    }

    func incrementTripCount() {
        updateCurrentProfile { profile in
            profile.totalTripsCount += 1
        }
    }

    func addDistance(_ distanceInMeters: Double) {
        updateCurrentProfile { profile in
            profile.totalDistanceMeters += max(0, distanceInMeters)
        }
    }

    private func updateCurrentProfile(_ change: (inout UserProfile) -> Void) {
        var updatedProfile = currentProfile
        change(&updatedProfile)
        currentProfile = updatedProfile
        saveProfile()
    }

    private static func loadProfile(storageKey: String) -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return nil
        }

        do {
            return try JSONDecoder().decode(UserProfile.self, from: data)
        } catch {
            return nil
        }
    }

    private func saveProfile() {
        do {
            let data = try JSONEncoder().encode(currentProfile)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // TODO: Surface persistence failures if the app later needs stricter handling.
        }
    }
}
