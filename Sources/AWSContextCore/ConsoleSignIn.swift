import Foundation

public struct TemporaryCredentials: Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String
}

/// Builds a URL that opens the AWS Management Console signed in as a given profile.
///
/// - SSO profiles use the access portal's shortcut link, so the browser goes through
///   the normal Identity Center login and lands in the right account and role.
/// - Everything else gets temporary credentials from the AWS CLI and exchanges them
///   for a console sign-in token via the AWS federation endpoint.
public enum ConsoleSignIn {
    public static let federationEndpoint = URL(string: "https://signin.aws.amazon.com/federation")!

    public static func url(for profile: Profile, cli: AWSCLI,
                           session: URLSession = .shared) async throws -> URL {
        let destination = consoleURL(region: profile.region)
        if profile.kind == .sso, let sso = profile.sso, let accountId = profile.accountId,
           let roleName = profile.roleName,
           let shortcut = ssoShortcutURL(startURL: sso.startURL, accountId: accountId,
                                         roleName: roleName, destination: destination) {
            return shortcut
        }

        let (credentials, isFederationToken) = try await temporaryCredentials(for: profile.name, cli: cli)
        // SessionDuration is rejected for federation tokens and chained roles; retry without it.
        let durations: [Int?] = isFederationToken ? [nil] : [43_200, nil]
        var lastError: Error?
        for duration in durations {
            do {
                let token = try await signinToken(for: credentials, duration: duration, session: session)
                return loginURL(signinToken: token, destination: destination)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AWSCLIError.failed("Could not sign in to the AWS console.")
    }

    // MARK: Building blocks

    public static func consoleURL(region: String?) -> URL {
        guard let region, !region.isEmpty else { return URL(string: "https://console.aws.amazon.com/console/home")! }
        return URL(string: "https://\(region).console.aws.amazon.com/console/home?region=\(region)")!
    }

    public static func ssoShortcutURL(startURL: String, accountId: String, roleName: String,
                                      destination: URL?) -> URL? {
        var base = startURL
        while base.hasSuffix("/") || base.hasSuffix("#") { base.removeLast() }
        var items = [("account_id", accountId), ("role_name", roleName)]
        if let destination { items.append(("destination", destination.absoluteString)) }
        return URL(string: "\(base)/#/console?\(query(items))")
    }

    public static func loginURL(signinToken: String, destination: URL) -> URL {
        URL(string: federationEndpoint.absoluteString + "?" + query([
            ("Action", "login"),
            ("Issuer", "AWSContext"),
            ("Destination", destination.absoluteString),
            ("SigninToken", signinToken),
        ]))!
    }

    /// Strict form encoding: everything except unreserved characters is escaped.
    static func query(_ items: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }

    /// Returns session credentials and whether they came from `GetFederationToken`.
    static func temporaryCredentials(for profile: String, cli: AWSCLI) async throws -> (TemporaryCredentials, Bool) {
        let exported = try await cli.run(["configure", "export-credentials", "--profile", profile, "--format", "process"])
        if let credentials = parseCredentials(exported), !credentials.sessionToken.isEmpty {
            return (credentials, false)
        }
        // Long-term IAM user keys can't open the console directly; mint a federation token.
        // Its permissions are the intersection of the user's own policies and this one.
        let federated = try await cli.run([
            "sts", "get-federation-token", "--profile", profile, "--name", "AWSContext",
            "--duration-seconds", "43200", "--output", "json",
            "--policy-arns", "arn=arn:aws:iam::aws:policy/AdministratorAccess",
        ])
        guard let credentials = parseCredentials(federated), !credentials.sessionToken.isEmpty else {
            throw AWSCLIError.failed("The AWS CLI returned no temporary credentials for “\(profile)”.")
        }
        return (credentials, true)
    }

    /// Parses `export-credentials --format process` output or STS JSON (`{"Credentials": {…}}`).
    public static func parseCredentials(_ json: String) -> TemporaryCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        let credentials = object["Credentials"] as? [String: Any] ?? object
        guard let keyId = credentials["AccessKeyId"] as? String,
              let secret = credentials["SecretAccessKey"] as? String else { return nil }
        return TemporaryCredentials(accessKeyId: keyId, secretAccessKey: secret,
                                    sessionToken: credentials["SessionToken"] as? String ?? "")
    }

    static func signinToken(for credentials: TemporaryCredentials, duration: Int?,
                            session: URLSession) async throws -> String {
        let sessionJSON = try JSONSerialization.data(withJSONObject: [
            "sessionId": credentials.accessKeyId,
            "sessionKey": credentials.secretAccessKey,
            "sessionToken": credentials.sessionToken,
        ])
        var items = [("Action", "getSigninToken")]
        if let duration { items.append(("SessionDuration", String(duration))) }
        items.append(("Session", String(decoding: sessionJSON, as: UTF8.self)))

        let url = URL(string: federationEndpoint.absoluteString + "?" + query(items))!
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["SigninToken"] as? String else {
            throw AWSCLIError.failed("AWS rejected the console sign-in request.")
        }
        return token
    }
}
