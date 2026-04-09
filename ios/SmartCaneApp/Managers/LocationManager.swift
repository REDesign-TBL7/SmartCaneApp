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
    let label: String?
    let name: String
    let subtitle: String
    let systemImageName: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        label ?? name
    }

    var displaySubtitle: String {
        guard let label, !label.isEmpty else {
            return subtitle
        }

        return subtitle.isEmpty ? name : "\(name), \(subtitle)"
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
    @Published var debugLogEntries: [DebugLogEntry] = []

    private let locationManager = CLLocationManager()
    private let searchCompleter = MKLocalSearchCompleter()
    private let defaultSearchCenter = CLLocationCoordinate2D(latitude: 1.3521, longitude: 103.8198)
    private let profileManager: ProfileManager
    private let connectionManager: CaneConnectionManager
    private let fusionManager: GuidanceFusionManager
    private var cancellables: Set<AnyCancellable> = []
    private var hasRecordedDistanceForCurrentTrip = false
    private var currentRouteSummary = "Route pending"
    private var hasRequestedAlwaysLocationAccess = false

    var hasActiveNavigation: Bool {
        activeDestination != nil
    }

    var navigationStatusValue: String {
        activeDestination?.displayName ?? "No current navigation"
    }

    var favoriteCountText: String {
        String(favoritePlaces.count)
    }

    var commonFavoriteLabels: [String] {
        ["Home", "Work", "School", "Transit", "Clinic", "Other"]
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
        configureBackgroundLocationUpdatesIfAllowed()
        locationManager.pausesLocationUpdatesAutomatically = false

        searchCompleter.delegate = self
        searchCompleter.resultTypes = [.address, .pointOfInterest]
        searchCompleter.region = searchRegion(around: defaultSearchCenter)

        bindProfileData()
        appendDebugLog("location", "Location manager initialized")
        requestLocationAccess()
    }

    /// `allowsBackgroundLocationUpdates` crashes if the app bundle is missing
    /// `UIBackgroundModes` with the `location` value. Keep this check here so
    /// future project setting changes fail safely instead of crashing on launch.
    private func configureBackgroundLocationUpdatesIfAllowed() {
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        locationManager.allowsBackgroundLocationUpdates = backgroundModes?.contains("location") == true
    }

    /// Starts the normal iOS location permission flow.
    func requestLocationAccess() {
        let status = locationManager.authorizationStatus
        appendDebugLog("location", "Authorization status \(status.rawValue)")

        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
        case .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            locationManager.requestLocation()
            if !hasRequestedAlwaysLocationAccess {
                hasRequestedAlwaysLocationAccess = true
                locationManager.requestAlwaysAuthorization()
            }
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
            appendDebugLog("search", "Confirmed result \(resolvedDestination.displayName)")
            activateNavigation(to: resolvedDestination)
            await updateRouteForActiveDestination()
            return true
        } catch {
            appendDebugLog("search", "Failed to confirm result \(result.displayName): \(error.localizedDescription)")
            return false
        }
    }

    /// Toggles one autocomplete result directly from the search list.
    func toggleSearchResultFavorite(_ result: LocationSearchResult, label: String? = nil) async {
        if let existingPlace = matchingFavoritePlace(for: result) {
            removeFavoritePlace(existingPlace)
            return
        }

        do {
            let resolvedDestination = try await resolveSearchResult(result)
            addResolvedDestinationToFavorites(resolvedDestination, label: label)
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
        appendDebugLog("favorites", "Selected favorite \(place.displayTitle)")
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
        appendDebugLog("recent", "Selected recent route \(route.destinationName)")
        activateNavigation(to: destination)

        Task {
            await updateRouteForActiveDestination()
        }
    }

    /// Starts navigation from a spoken place name, for example "search for Raffles MRT".
    /// This bypasses the visual autocomplete list so voice mode stays low-friction.
    func startNavigationFromVoiceQuery(_ query: String) async -> String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return "Please say a destination after search for."
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmedQuery
        if let currentLocationCoordinate {
            request.region = MKCoordinateRegion(
                center: currentLocationCoordinate,
                latitudinalMeters: 12000,
                longitudinalMeters: 12000
            )
        } else {
            request.region = searchRegion(around: defaultSearchCenter)
        }
        request.resultTypes = [.address, .pointOfInterest]

        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let firstItem = response.mapItems.first,
                  let coordinate = firstItem.placemark.location?.coordinate else {
                return "I could not find \(trimmedQuery). Please try another place name."
            }

            let destination = ResolvedLocation(
                name: firstItem.name ?? trimmedQuery,
                subtitle: firstItem.placemark.title ?? "",
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            )

            appendDebugLog("search", "Voice query resolved \(trimmedQuery) to \(destination.displayName)")
            activateNavigation(to: destination)
            await updateRouteForActiveDestination()
            return "Starting navigation to \(destination.name)."
        } catch {
            appendDebugLog("search", "Voice query failed for \(trimmedQuery)")
            return "I could not find \(trimmedQuery). Please try another place name."
        }
    }

    /// Starts navigation to a saved place by spoken name, such as "home".
    func selectFavorite(named spokenName: String) -> Bool {
        let normalizedName = spokenName.normalizedVoiceCommandText
        guard let place = favoritePlaces.first(where: { place in
            place.name.normalizedVoiceCommandText == normalizedName
            || place.label?.normalizedVoiceCommandText == normalizedName
        }) else {
            return false
        }

        selectFavorite(place)
        return true
    }

    /// Returns the app to the empty navigation state.
    func clearNavigation() {
        appendDebugLog("navigation", "Cleared active navigation")
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

    func removeFavoritePlace(_ place: SavedPlace) {
        favoritePlaces.removeAll { savedPlace in
            savedPlace.id == place.id
        }
        profileManager.updateFavoritePlaces(favoritePlaces)
    }

    func updateFavoritePlaceLabel(_ place: SavedPlace, label: String?) {
        guard let index = favoritePlaces.firstIndex(where: { $0.id == place.id }) else {
            return
        }

        favoritePlaces[index] = SavedPlace(
            id: place.id,
            label: label,
            name: place.name,
            subtitle: place.subtitle,
            systemImageName: systemImageName(forFavoriteLabel: label),
            latitude: place.latitude,
            longitude: place.longitude
        )
        profileManager.updateFavoritePlaces(favoritePlaces)
    }

    private func addResolvedDestinationToFavorites(_ resolvedDestination: ResolvedLocation, label: String? = nil) {
        guard matchingFavoritePlace(for: resolvedDestination) == nil else {
            return
        }

        favoritePlaces.insert(
            SavedPlace(
                label: label,
                name: resolvedDestination.name,
                subtitle: resolvedDestination.subtitle.isEmpty ? "Saved by user" : resolvedDestination.subtitle,
                systemImageName: systemImageName(forFavoriteLabel: label),
                latitude: resolvedDestination.latitude,
                longitude: resolvedDestination.longitude
            ),
            at: 0
        )

        profileManager.updateFavoritePlaces(favoritePlaces)
    }

    private func matchingFavoritePlace(for result: LocationSearchResult) -> SavedPlace? {
        favoritePlaces.first { place in
            let savedDisplayName = "\(place.name), \(place.subtitle)".lowercased()
            let resultDisplayName = result.displayName.lowercased()
            return savedDisplayName == resultDisplayName || place.name.lowercased() == result.title.lowercased()
        }
    }

    private func systemImageName(forFavoriteLabel label: String?) -> String {
        switch label?.normalizedVoiceCommandText {
        case "home":
            return "house.fill"
        case "work":
            return "briefcase.fill"
        case "school":
            return "graduationcap.fill"
        case "transit":
            return "tram.fill"
        case "clinic":
            return "cross.case.fill"
        default:
            return "star.fill"
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
        appendDebugLog("navigation", "Activated destination \(destination.displayName)")
        profileManager.incrementTripCount()
        insertRecentRoute(for: destination)
    }

    private func updateRouteForActiveDestination() async {
        guard let destination = activeDestination else {
            return
        }

        guard let currentLocationCoordinate else {
            currentInstruction = "Waiting for your current location."
            appendDebugLog("routing", "Route update waiting for current location")
            return
        }

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: currentLocationCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        // This app currently uses MapKit directions, not the Google Maps Directions API.
        // Keep walking mode explicit on every directions request for cane guidance.
        request.transportType = .walking
        appendDebugLog("routing", "Requesting walking route to \(destination.displayName)")

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
                appendDebugLog("routing", "First step: \(firstInstruction)")
                appendDebugLog("routing", "Mapped step to command \(command.rawValue)")
                fusionManager.applyFusedCommand(baseCommand: command, instructionText: firstInstruction)
            } else {
                currentInstruction = "Navigating to \(destination.name)"
                appendDebugLog("routing", "No explicit route step, defaulting to FORWARD")
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
            appendDebugLog("routing", "Route request failed for \(destination.displayName): \(error.localizedDescription)")
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
            let delta = normalizedBearingDelta(
                desiredBearing: desiredBearing,
                heading: connectionManager.caneState.motorUnitHeadingDegrees
            )

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
extension LocationManager: @preconcurrency CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocationAccess()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latestLocation = locations.last else {
            return
        }

        currentLocationCoordinate = latestLocation.coordinate
        appendDebugLog(
            "location",
            "Updated phone location to \(String(format: "%.5f", latestLocation.coordinate.latitude)), \(String(format: "%.5f", latestLocation.coordinate.longitude))"
        )
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
        appendDebugLog("location", "Location update failed: \(error.localizedDescription)")
    }
}

@MainActor
extension LocationManager: @preconcurrency MKLocalSearchCompleterDelegate {
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        searchResults = completer.results.map { result in
            LocationSearchResult(
                title: result.title,
                subtitle: result.subtitle,
                completion: result
            )
        }
        appendDebugLog("search", "Completer returned \(searchResults.count) result(s)")
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        searchResults = []
        appendDebugLog("search", "Completer failed: \(error.localizedDescription)")
    }
}

private enum LocationResolutionError: Error {
    case noResult
    case noRoute
}

private extension LocationManager {
    func appendDebugLog(_ subsystem: String, _ message: String) {
        debugLogEntries.insert(DebugLogEntry(subsystem: subsystem, message: message), at: 0)
        if debugLogEntries.count > 160 {
            debugLogEntries.removeLast(debugLogEntries.count - 160)
        }
    }
}
