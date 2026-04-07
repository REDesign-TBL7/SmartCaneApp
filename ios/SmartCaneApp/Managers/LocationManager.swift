/*
 File: LocationManager.swift
 Purpose:
 This file manages live location, destination search, favourites, recent places,
 and walking route calculation for the app.

 Why it is structured this way:
 SwiftUI views stay simple when all navigation logic lives in one
 ObservableObject. The views only read published values and call small methods.
*/

import Foundation
import CoreLocation
import MapKit
import Combine

/// A real place that has already been resolved into map coordinates.
struct ResolvedLocation: Identifiable, Hashable, Codable {
    var id = UUID()
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        subtitle.isEmpty ? name : "\(name), \(subtitle)"
    }
}

/// A saved location shown in the favourites list.
struct SavedPlace: Identifiable, Hashable, Codable {
    var id = UUID()
    let name: String
    let subtitle: String
    let systemImageName: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A previously confirmed destination shown in history.
struct NavigationHistoryItem: Identifiable, Hashable, Codable {
    var id = UUID()
    let destinationName: String
    let summary: String
    let dayLabel: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A lightweight search result built from MKLocalSearchCompleter.
struct LocationSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let completion: MKLocalSearchCompletion

    var displayName: String {
        subtitle.isEmpty ? title : "\(title), \(subtitle)"
    }
}

@MainActor
final class LocationManager: NSObject, ObservableObject {
    /// Text currently typed into the destination field.
    @Published var searchText = "" {
        didSet {
            handleSearchTextChange()
        }
    }

    /// Search suggestions shown under the text field.
    @Published var searchResults: [LocationSearchResult] = []

    /// The latest spoken-friendly navigation instruction.
    @Published var currentInstruction = "No active navigation"

    /// Live location from CoreLocation.
    @Published var currentLocationCoordinate: CLLocationCoordinate2D?

    /// Destination currently being navigated to.
    @Published var activeDestination: ResolvedLocation?

    /// Stats shown on the profile screen.
    @Published var totalTripsText = "0"
    @Published var totalDistanceText = "0 km"

    @Published var favoritePlaces: [SavedPlace] = []
    @Published var recentRoutes: [NavigationHistoryItem] = []

    private let locationManager = CLLocationManager()
    private let searchCompleter = MKLocalSearchCompleter()
    private let defaultSearchCenter = CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
    private let profileManager: ProfileManager
    private let connectionManager: CaneConnectionManager
    private let fusionManager: GuidanceFusionManager
    private var cancellables: Set<AnyCancellable> = []
    private var hasRecordedDistanceForCurrentTrip = false
    private var currentRouteSummary = "Route pending"

    var hasActiveNavigation: Bool {
        activeDestination != nil
    }

    var navigationStatusValue: String {
        activeDestination?.displayName ?? "No current navigation"
    }

    var favoriteCountText: String {
        String(favoritePlaces.count)
    }

    private func bindProfileData() {
        profileManager.$currentProfile
            .receive(on: RunLoop.main)
            .sink { [weak self] profile in
                self?.applyPersistedProfile(profile)
            }
            .store(in: &cancellables)

        applyPersistedProfile(profileManager.currentProfile)
    }

    private func applyPersistedProfile(_ profile: UserProfile) {
        favoritePlaces = profile.favoritePlaces
        recentRoutes = profile.recentRoutes
        totalTripsText = String(profile.totalTripsCount)
        totalDistanceText = formatProfileDistance(profile.totalDistanceMeters)
    }

    init(profileManager: ProfileManager, connectionManager: CaneConnectionManager, fusionManager: GuidanceFusionManager) {
        self.profileManager = profileManager
        self.connectionManager = connectionManager
        self.fusionManager = fusionManager
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address, .pointOfInterest]
        searchCompleter.region = searchRegion(around: defaultSearchCenter)

        bindProfileData()
        requestLocationAccess()
    }

    /// Starts the normal iOS location permission flow.
    func requestLocationAccess() {
        let status = locationManager.authorizationStatus

        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    /// Clears the temporary search UI state whenever the search page is opened again.
    func prepareForSearchEntry() {
        searchText = ""
        searchResults = []
    }

    /// Called when the user taps an autocomplete suggestion and wants to navigate immediately.
    @discardableResult
    func confirmSearchResult(_ result: LocationSearchResult) async -> Bool {
        do {
            searchText = result.displayName
            searchResults = []

            let resolvedDestination = try await resolveSearchResult(result)
            activateNavigation(to: resolvedDestination)
            await updateRouteForActiveDestination()
            return true
        } catch {
            return false
        }
    }

    /// Toggles one autocomplete result directly from the search list.
    func toggleSearchResultFavorite(_ result: LocationSearchResult) async {
        if let existingPlace = matchingFavoritePlace(for: result) {
            removeFavoritePlace(existingPlace)
            return
        }

        do {
            let resolvedDestination = try await resolveSearchResult(result)
            addResolvedDestinationToFavorites(resolvedDestination)
        } catch {
            return
        }
    }

    /// Starts navigation from an already-saved favourite.
    func selectFavorite(_ place: SavedPlace) {
        let destination = ResolvedLocation(
            name: place.name,
            subtitle: place.subtitle,
            latitude: place.latitude,
            longitude: place.longitude
        )

        searchText = destination.displayName
        activateNavigation(to: destination)

        Task {
            await updateRouteForActiveDestination()
        }
    }

    /// Starts navigation from a location in history.
    func selectRecent(_ route: NavigationHistoryItem) {
        let destination = ResolvedLocation(
            name: route.destinationName,
            subtitle: "",
            latitude: route.latitude,
            longitude: route.longitude
        )

        searchText = destination.name
        activateNavigation(to: destination)

        Task {
            await updateRouteForActiveDestination()
        }
    }

    /// Returns the app to the empty navigation state.
    func clearNavigation() {
        activeDestination = nil
        currentInstruction = "No active navigation"
        currentRouteSummary = "Route pending"
        hasRecordedDistanceForCurrentTrip = false
    }

    private func handleSearchTextChange() {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            searchResults = []
            return
        }

        searchCompleter.queryFragment = trimmedQuery
    }

    private func addResolvedDestinationToFavorites(_ resolvedDestination: ResolvedLocation) {
        guard matchingFavoritePlace(for: resolvedDestination) == nil else {
            return
        }

        favoritePlaces.insert(
            SavedPlace(
                name: resolvedDestination.name,
                subtitle: resolvedDestination.subtitle.isEmpty ? "Saved by user" : resolvedDestination.subtitle,
                systemImageName: "star.fill",
                latitude: resolvedDestination.latitude,
                longitude: resolvedDestination.longitude
            ),
            at: 0
        )

        profileManager.updateFavoritePlaces(favoritePlaces)
    }

    private func removeFavoritePlace(_ place: SavedPlace) {
        favoritePlaces.removeAll { savedPlace in
            savedPlace.id == place.id
        }
        profileManager.updateFavoritePlaces(favoritePlaces)
    }

    private func matchingFavoritePlace(for result: LocationSearchResult) -> SavedPlace? {
        favoritePlaces.first { place in
            let savedDisplayName = "\(place.name), \(place.subtitle)".lowercased()
            let resultDisplayName = result.displayName.lowercased()
            return savedDisplayName == resultDisplayName || place.name.lowercased() == result.title.lowercased()
        }
    }

    private func matchingFavoritePlace(for destination: ResolvedLocation) -> SavedPlace? {
        favoritePlaces.first { place in
            place.name.caseInsensitiveCompare(destination.name) == .orderedSame
            && place.subtitle.caseInsensitiveCompare(destination.subtitle.isEmpty ? "Saved by user" : destination.subtitle) == .orderedSame
        }
    }

    private func resolveSearchResult(_ result: LocationSearchResult) async throws -> ResolvedLocation {
        let request = MKLocalSearch.Request(completion: result.completion)
        if let currentLocationCoordinate {
            request.region = MKCoordinateRegion(
                center: currentLocationCoordinate,
                latitudinalMeters: 12000,
                longitudinalMeters: 12000
            )
        } else {
            request.region = searchRegion(around: defaultSearchCenter)
        }

        let response = try await MKLocalSearch(request: request).start()
        guard let firstItem = response.mapItems.first,
              let coordinate = firstItem.placemark.location?.coordinate else {
            throw LocationResolutionError.noResult
        }

        return ResolvedLocation(
            name: firstItem.name ?? result.title,
            subtitle: firstItem.placemark.title ?? result.subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
    }

    private func activateNavigation(to destination: ResolvedLocation) {
        activeDestination = destination
        currentInstruction = "Navigating to \(destination.name)"
        currentRouteSummary = "Route pending"
        hasRecordedDistanceForCurrentTrip = false
        profileManager.incrementTripCount()
        insertRecentRoute(for: destination)
    }

    private func updateRouteForActiveDestination() async {
        guard let destination = activeDestination else {
            return
        }

        guard let currentLocationCoordinate else {
            currentInstruction = "Waiting for your current location."
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocationCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        // This app currently uses MapKit directions, not the Google Maps Directions API.
        // Keep walking mode explicit on every directions request for cane guidance.
        request.transportType = .walking

        do {
            let response = try await MKDirections(request: request).calculate()
            guard let route = response.routes.first else {
                throw LocationResolutionError.noRoute
            }

            let travelTimeText = formatTravelTime(route.expectedTravelTime)
            currentRouteSummary = "\(travelTimeText) walk"

            if let firstInstruction = route.steps.first(where: { !$0.instructions.isEmpty })?.instructions {
                currentInstruction = firstInstruction
                let command = commandForInstruction(firstInstruction)
                fusionManager.applyFusedCommand(baseCommand: command, instructionText: firstInstruction)
            } else {
                currentInstruction = "Navigating to \(destination.name)"
                fusionManager.applyFusedCommand(baseCommand: .forward, instructionText: currentInstruction)
            }

            if !hasRecordedDistanceForCurrentTrip {
                profileManager.addDistance(route.distance)
                hasRecordedDistanceForCurrentTrip = true
            }

            if !recentRoutes.isEmpty,
               recentRoutes[0].destinationName.caseInsensitiveCompare(destination.name) == .orderedSame {
                recentRoutes[0] = NavigationHistoryItem(
                    destinationName: destination.name,
                    summary: currentRouteSummary,
                    dayLabel: "Now",
                    latitude: destination.latitude,
                    longitude: destination.longitude
                )
                profileManager.updateRecentRoutes(recentRoutes)
            }
        } catch {
            currentRouteSummary = "Route pending"
            currentInstruction = "Route unavailable from current location."
            fusionManager.applyFusedCommand(baseCommand: .stop, instructionText: currentInstruction)
        }
    }

    private func insertRecentRoute(for destination: ResolvedLocation) {
        recentRoutes.removeAll { route in
            route.destinationName.caseInsensitiveCompare(destination.name) == .orderedSame
        }

        recentRoutes.insert(
            NavigationHistoryItem(
                destinationName: destination.name,
                summary: currentRouteSummary,
                dayLabel: "Now",
                latitude: destination.latitude,
                longitude: destination.longitude
            ),
            at: 0
        )

        if recentRoutes.count > 8 {
            recentRoutes.removeLast(recentRoutes.count - 8)
        }

        profileManager.updateRecentRoutes(recentRoutes)
    }

    private func formatTravelTime(_ travelTime: TimeInterval) -> String {
        let minutes = max(1, Int((travelTime / 60).rounded()))
        return "\(minutes) min"
    }

    private func formatProfileDistance(_ distanceInMeters: Double) -> String {
        guard distanceInMeters > 0 else {
            return "0 km"
        }

        return String(format: "%.1f km", distanceInMeters / 1000)
    }

    /// Converts a natural-language route step into the simple haptic command set.
    private func commandForInstruction(_ instruction: String) -> NavigationCommand {
        let lowercaseInstruction = instruction.lowercased()

        if lowercaseInstruction.contains("left") {
            return .left
        }

        if lowercaseInstruction.contains("right") {
            return .right
        }

        if lowercaseInstruction.contains("continue")
            || lowercaseInstruction.contains("straight")
            || lowercaseInstruction.contains("head")
            || lowercaseInstruction.contains("proceed") {
            return .forward
        }

        if let currentLocationCoordinate,
           let activeDestination {
            let desiredBearing = bearingDegrees(from: currentLocationCoordinate, to: activeDestination.coordinate)
            let delta = normalizedBearingDelta(desiredBearing: desiredBearing, heading: connectionManager.caneState.headingDegrees)

            if delta > 18 {
                return .right
            }

            if delta < -18 {
                return .left
            }
        }

        return .forward
    }

    private func bearingDegrees(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let startLongitude = start.longitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let endLongitude = end.longitude * .pi / 180

        let dLongitude = endLongitude - startLongitude
        let y = sin(dLongitude) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude) - sin(startLatitude) * cos(endLatitude) * cos(dLongitude)
        let radiansBearing = atan2(y, x)
        let degreesBearing = radiansBearing * 180 / .pi

        if degreesBearing < 0 {
            return degreesBearing + 360
        }

        return degreesBearing
    }

    private func normalizedBearingDelta(desiredBearing: Double, heading: Double) -> Double {
        var delta = desiredBearing - heading

        while delta > 180 {
            delta -= 360
        }

        while delta < -180 {
            delta += 360
        }

        return delta
    }

    private func searchRegion(around center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            latitudinalMeters: 15000,
            longitudinalMeters: 15000
        )
    }
}

@MainActor
extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocationAccess()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else {
            return
        }

        currentLocationCoordinate = latestLocation.coordinate
        connectionManager.updatePhoneLocation(
            latitude: latestLocation.coordinate.latitude,
            longitude: latestLocation.coordinate.longitude
        )
        searchCompleter.region = searchRegion(around: latestLocation.coordinate)

        if activeDestination != nil {
            Task {
                await updateRouteForActiveDestination()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if activeDestination != nil {
            currentInstruction = "Could not update your location."
        }
    }
}

@MainActor
extension LocationManager: MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        searchResults = completer.results.map { result in
            LocationSearchResult(
                title: result.title,
                subtitle: result.subtitle,
                completion: result
            )
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searchResults = []
    }
}

private enum LocationResolutionError: Error {
    case noResult
    case noRoute
}
