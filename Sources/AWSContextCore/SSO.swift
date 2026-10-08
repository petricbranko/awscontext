import CryptoKit
import Foundation

/// The IAM Identity Center (SSO) settings behind a profile.
public struct SSOInfo: Hashable {
    /// The profile that owns the SSO settings, i.e. what `aws sso login --profile` needs.
    public var profile: String
    /// Name of the `[sso-session …]` section, if the modern format is used.
    public var sessionName: String?
    public var startURL: String
    public var region: String?
}

public enum SSOSessionStatus: Equatable {
    /// Signed in; the token is valid until the given date.
    case valid(until: Date)
    /// The access token expired but the CLI holds a refresh token, so it may renew silently.
    case refreshable
    case expired
    case signedOut
}

/// Reads the AWS CLI's SSO token cache (`~/.aws/sso/cache`) without touching any secrets.
public enum SSOTokenCache {
    public static func status(for info: SSOInfo, cacheDirectory: URL, now: Date = Date()) -> SSOSessionStatus {
        let url = cacheDirectory.appendingPathComponent(cacheFileName(for: info))
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiresAt = (json["expiresAt"] as? String).flatMap(parseDate) else {
            return .signedOut
        }
        if expiresAt > now { return .valid(until: expiresAt) }
        if json["refreshToken"] != nil,
           (json["registrationExpiresAt"] as? String).flatMap(parseDate).map({ $0 > now }) ?? true {
            return .refreshable
        }
        return .expired
    }

    /// The CLI names cache files after the SHA-1 of the session name (or start URL for legacy profiles).
    public static func cacheFileName(for info: SSOInfo) -> String {
        let key = info.sessionName ?? info.startURL
        let digest = Insecure.SHA1.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    static func parseDate(_ text: String) -> Date? {
        let normalized = text.hasSuffix("UTC") ? String(text.dropLast(3)) + "Z" : text
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: normalized)
    }
}
