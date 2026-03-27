/*
 File: UserProfile.swift
 Purpose:
 This file defines the single local user profile stored on the device.
*/

import Foundation

struct UserProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var favoritePlaces: [SavedPlace] = []
    var recentRoutes: [NavigationHistoryItem] = []
    var totalTripsCount: Int = 0
    var totalDistanceMeters: Double = 0
    var createdAt = Date()
}
