#if canImport(Nitrakit)
import Nitrakit
#endif
import Foundation

/// The app's license. `set` installs the key (the SDK reads the bundle ID itself) with the last
/// license status it stored. The SDK then checks for a newer status in the background, at most
/// daily (the editor checks too when it opens): plan changes and renewals arrive without an app
/// update. Offline or unreachable, nothing changes.
public enum NitrakitLicense {
    private static let defaults = UserDefaults.standard
    private static let prefix = "dev.nitrakit.license."
    private static let day: TimeInterval = 24 * 60 * 60
    private static let lock = NSLock()
    nonisolated(unsafe) private static var checking = false

    /// A newer status changed the license (main queue).
    nonisolated(unsafe) public static var onChange: ((LicenseInfo) -> Void)?

    @discardableResult
    public static func set(_ key: String) -> LicenseInfo {
        if defaults.string(forKey: prefix + "key") != key {
            for k in ["status", "seen", "checked"] { defaults.removeObject(forKey: prefix + k) }
            defaults.set(key, forKey: prefix + "key")
        }
        let info = setLicense(
            key: key,
            status: defaults.string(forKey: prefix + "status") ?? "",
            seen: defaults.string(forKey: prefix + "seen") ?? ""
        )
        defaults.set(info.seen, forKey: prefix + "seen")
        refresh()
        return info
    }

    public static var info: LicenseInfo { licenseInfo() }

    /// Asks the license server for the current status, unless it did within a day (`force`: now).
    public static func refresh(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let skip = checking || (!force && now - defaults.double(forKey: prefix + "checked") < day)
        if !skip { checking = true }
        lock.unlock()
        guard !skip else { return }
        let address = licenseStatusUrl()
        guard let url = URL(string: address), !address.isEmpty else {
            lock.lock(); checking = false; lock.unlock()
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { lock.lock(); checking = false; lock.unlock() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = data.flatMap({ String(data: $0, encoding: .utf8) })?
                      .trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            defaults.set(now, forKey: prefix + "checked")
            guard let info = try? applyLicenseStatus(status: body) else { return }
            defaults.set(body, forKey: prefix + "status")
            defaults.set(info.seen, forKey: prefix + "seen")
            DispatchQueue.main.async { onChange?(info) }
        }.resume()
    }
}
