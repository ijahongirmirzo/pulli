import DeviceAPI
import PulliProtocol

/// Journal setting keys for measured copy speeds, per phone and link.
enum MeasuredRates {
    static func key(_ device: DeviceKey, _ link: LinkSpeed) -> String {
        "rate:\(device.description):\(link.rawValue)"
    }
}
