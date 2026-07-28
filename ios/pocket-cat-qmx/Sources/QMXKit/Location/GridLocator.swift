// One-shot location fix, turned into a Maidenhead locator.
//
// Deliberately not a running subscription: the operator taps a button, we
// take one fix and stop. A portable station moves between activations, not
// during one.

import Foundation
import Observation
#if canImport(CoreLocation)
import CoreLocation
#endif

@MainActor
@Observable
public final class GridLocator {
    public enum State: Equatable, Sendable {
        case idle
        case locating
        case failed(String)
    }

    public private(set) var state: State = .idle

    public init() {}

    #if canImport(CoreLocation)
    private let manager = CLLocationManager()
    private var delegate: Delegate?

    /// Requests permission if needed, takes one fix, and returns its
    /// locator. Returns nil on denial, timeout or error, with the reason
    /// left in `state`.
    public func currentLocator(precision: Int = 6) async -> String? {
        state = .locating
        let result: CLLocation?
        do {
            result = try await withCheckedThrowingContinuation { continuation in
                let delegate = Delegate(continuation: continuation)
                self.delegate = delegate
                manager.delegate = delegate
                manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
                manager.requestWhenInUseAuthorization()
                manager.requestLocation()
            }
        } catch {
            state = .failed(Self.describe(error))
            return nil
        }
        guard let location = result else {
            state = .failed("No location available")
            return nil
        }
        state = .idle
        return Maidenhead.locator(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            precision: precision)
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? CLError else { return "Location failed" }
        switch error.code {
        case .denied:
            return "Location access denied — enable it in iOS Settings"
        case .locationUnknown:
            return "Couldn't get a fix — try outdoors"
        default:
            return "Location failed"
        }
    }

    /// Bridges the delegate callbacks into the continuation, and makes sure
    /// exactly one of them resumes it.
    private final class Delegate: NSObject, CLLocationManagerDelegate {
        private var continuation:
            CheckedContinuation<CLLocation?, Error>?

        init(continuation: CheckedContinuation<CLLocation?, Error>) {
            self.continuation = continuation
        }

        private func finish(_ result: Result<CLLocation?, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }

        func locationManager(_ manager: CLLocationManager,
                             didUpdateLocations locations: [CLLocation]) {
            finish(.success(locations.last))
        }

        func locationManager(_ manager: CLLocationManager,
                             didFailWithError error: Error) {
            finish(.failure(error))
        }

        func locationManagerDidChangeAuthorization(
            _ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .denied, .restricted:
                finish(.failure(CLError(.denied)))
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                break // still undetermined; wait for the prompt
            }
        }
    }
    #else
    public func currentLocator(precision: Int = 6) async -> String? {
        state = .failed("Location isn't available on this platform")
        return nil
    }
    #endif
}
