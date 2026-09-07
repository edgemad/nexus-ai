import Foundation
import CoreLocation

/// Resolves "where am I?" questions using Core Location. Falls back to nil when
/// location is denied/restricted/unavailable so the caller can use an
/// approximate network-based answer instead.
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    /// Fresh manager per request so a clean authorization flow always starts.
    private var manager: CLLocationManager?
    private var continuation: CheckedContinuation<CLLocation?, Never>?
    private var resumed = false

    private override init() {
        super.init()
    }

    /// Returns a friendly sentence describing the user's location, or nil when
    /// the user hasn't granted (or can't provide) access.
    func currentLocationDescription() async -> String? {
        guard let loc = await resolveLocation() else { return nil }
        return await placeDescription(for: loc)
    }

    /// Requests authorization if needed, then a one-shot location fix.
    private func resolveLocation() async -> CLLocation? {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .authorized:
            return await requestFix(requestAuth: false)
        case .notDetermined:
            return await requestFix(requestAuth: true)
        default:
            return nil
        }
    }

    private func requestFix(requestAuth: Bool) async -> CLLocation? {
        let result = await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
            let m = CLLocationManager()
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager = m
            continuation = cont
            resumed = false

            // Watchdog: an unanswered TCC prompt (or a slow first GPS fix after
            // permission is granted) must never leave the chat stuck on
            // "thinking". A nil result falls back to the IP-derived answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.finish(nil)
            }

let status = m.authorizationStatus
            if status == .notDetermined, requestAuth {
                m.requestWhenInUseAuthorization()   // TCC prompt appears here
            } else if status == .authorized {
                m.requestLocation()
            } else {
                finish(nil)
            }
        }
        manager = nil
        return result
    }

    private func finish(_ location: CLLocation?) {
        guard !resumed else { return }
        resumed = true
        continuation?.resume(returning: location)
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if status == .authorized {
            manager.requestLocation()
        } else if status != .notDetermined {
            finish(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    // MARK: - Reverse geocoding

    /// Converts a coordinate to "City, State, Country" (or coordinates when the
    /// signed-in geocoder isn't available).
    private func placeDescription(for loc: CLLocation) async -> String {
        let geocoder = CLGeocoder()
        var place: CLPlacemark?
        do {
            place = try await geocoder.reverseGeocodeLocation(
                loc,
                preferredLocale: Locale(identifier: "en_US")
            ).first
        } catch {
            place = nil
        }

        var parts: [String] = []
        if let place {
            if let city = place.locality, !city.isEmpty { parts.append(city) }
            if let state = place.administrativeArea, !state.isEmpty { parts.append(state) }
            if let country = place.country, !country.isEmpty { parts.append(country) }
        }
        if parts.isEmpty {
            parts.append(String(format: "%.3f, %.3f", loc.coordinate.latitude, loc.coordinate.longitude))
        }
        return parts.joined(separator: ", ")
    }
}