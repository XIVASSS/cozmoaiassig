import CoreLocation
import Foundation

@MainActor
final class PlaceLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var label = "Finding this place"
    @Published var city = ""
    @Published var country = "US"
    @Published var currency = "USD"
    @Published var ready = false

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            applyFallback()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            applyFallback()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] marks, _ in
            Task { @MainActor in
                guard let self else { return }
                let code = marks?.first?.isoCountryCode ?? "US"
                let city = marks?.first?.locality ?? marks?.first?.country
                self.apply(code: code, city: city)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        _ = error
        if !ready { applyFallback() }
    }

    private func apply(code: String, city: String?) {
        country = code
        currency = Locale(identifier: "en_\(code)").currency?.identifier ?? "USD"
        let place = city ?? (Locale.current.localizedString(forRegionCode: code) ?? code)
        self.city = place
        label = "\(place) · \(currency)"
        ready = true
    }

    private func applyFallback() {
        country = "US"
        currency = "USD"
        city = "United States"
        label = "United States · USD"
        ready = true
    }
}
