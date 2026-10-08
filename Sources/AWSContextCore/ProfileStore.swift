import Foundation

public struct AWSPaths: Equatable {
    public var credentials: URL
    public var config: URL
    /// Plain-text file holding the name of the active profile, handy for shell prompts.
    public var state: URL
    /// Where the AWS CLI caches SSO tokens.
    public var ssoCache: URL

    public init(credentials: URL, config: URL, state: URL, ssoCache: URL? = nil) {
        self.credentials = credentials
        self.config = config
        self.state = state
        self.ssoCache = ssoCache ?? state.deletingLastPathComponent().appendingPathComponent("sso/cache")
    }

    /// Standard AWS CLI locations, honouring `AWS_SHARED_CREDENTIALS_FILE` and `AWS_CONFIG_FILE`.
    ///
    /// `AWSCONTEXT_HOME` replaces `~/.aws` entirely (credentials, config, state and SSO cache),
    /// which is how `make demo` runs the app without touching real files.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AWSPaths {
        if let override = environment["AWSCONTEXT_HOME"], !override.isEmpty {
            let aws = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return AWSPaths(
                credentials: aws.appendingPathComponent("credentials"),
                config: aws.appendingPathComponent("config"),
                state: aws.appendingPathComponent("awscontext")
            )
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let aws = home.appendingPathComponent(".aws")
        func path(_ variable: String, _ fallback: String) -> URL {
            if let value = environment[variable], !value.isEmpty {
                return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
            }
            return aws.appendingPathComponent(fallback)
        }
        return AWSPaths(
            credentials: path("AWS_SHARED_CREDENTIALS_FILE", "credentials"),
            config: path("AWS_CONFIG_FILE", "config"),
            state: aws.appendingPathComponent("awscontext")
        )
    }
}

public struct Profile: Identifiable, Hashable {
    public enum Kind: String {
        case accessKeys = "Access keys"
        case sso = "SSO"
        case role = "Assume role"
        case process = "Credential process"
        case config = "Config only"
    }

    public var id: String { name }
    public var name: String
    public var region: String?
    public var kind: Kind
    public var accountId: String?
    public var roleName: String?
    /// SSO settings used to get credentials, either the profile's own or inherited via `source_profile`.
    public var sso: SSOInfo?

    public init(name: String, region: String? = nil, kind: Kind, accountId: String? = nil,
                roleName: String? = nil, sso: SSOInfo? = nil) {
        self.name = name
        self.region = region
        self.kind = kind
        self.accountId = accountId
        self.roleName = roleName
        self.sso = sso
    }
}

public struct NewProfile: Equatable {
    public var name: String
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String
    public var region: String
    public var output: String

    public init(name: String = "", accessKeyId: String = "", secretAccessKey: String = "",
                sessionToken: String = "", region: String = "", output: String = "") {
        self.name = name
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.output = output
    }
}

public enum ProfileError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)
    case notFound(String)
    case missingField(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): return "“\(name)” is not a valid profile name. Use letters, numbers, dots, dashes or underscores."
        case .alreadyExists(let name): return "A profile named “\(name)” already exists."
        case .notFound(let name): return "No profile named “\(name)” was found."
        case .missingField(let field): return "\(field) is required."
        }
    }
}

/// Reads and edits AWS CLI profiles.
///
/// Switching works by copying the chosen profile into the `[default]` section of
/// both files, so every tool and SDK picks it up without any shell setup.
public final class ProfileStore {
    public static let defaultName = "default"
    public static let backupProfileName = "default-backup"

    public let paths: AWSPaths
    private let fileManager = FileManager.default

    public init(paths: AWSPaths = .standard()) {
        self.paths = paths
    }

    // MARK: Reading

    public func profiles() -> [Profile] {
        let credentials = read(paths.credentials)
        let config = read(paths.config)

        var names: [String] = []
        for name in credentials.sectionNames where !names.contains(name) {
            names.append(name)
        }
        for section in config.sectionNames {
            if let name = Self.profileName(fromConfigSection: section), !names.contains(name) {
                names.append(name)
            }
        }

        return names
            .filter { $0 != Self.defaultName }
            .map { name in
                let configSection = Self.configSection(for: name)
                let keys = Set(config.pairs(in: configSection).map(\.key))
                let kind: Profile.Kind
                if keys.contains("role_arn") {
                    kind = .role
                } else if credentials.hasSection(name) || keys.contains("aws_access_key_id") {
                    kind = .accessKeys
                } else if keys.contains("sso_session") || keys.contains("sso_start_url") {
                    kind = .sso
                } else if keys.contains("credential_process") {
                    kind = .process
                } else {
                    kind = .config
                }
                let roleArn = config.value("role_arn", in: configSection)
                return Profile(
                    name: name,
                    region: config.value("region", in: configSection),
                    kind: kind,
                    accountId: config.value("sso_account_id", in: configSection) ?? roleArn.flatMap(Self.accountId(fromArn:)),
                    roleName: config.value("sso_role_name", in: configSection) ?? roleArn.flatMap(Self.roleName(fromArn:)),
                    sso: ssoInfo(for: name, config: config)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The profile currently copied into `[default]`, if any.
    public func activeProfileName() -> String? {
        let credentials = read(paths.credentials)
        let config = read(paths.config)
        let matches = profiles().map(\.name).filter { matchesDefault($0, credentials: credentials, config: config) }
        if let remembered = rememberedProfile(), matches.contains(remembered) {
            return remembered
        }
        return matches.first
    }

    // MARK: Writing

    public func activate(_ name: String) throws {
        var credentials = read(paths.credentials)
        var config = read(paths.config)
        let configSection = Self.configSection(for: name)
        guard credentials.hasSection(name) || config.hasSection(configSection) else {
            throw ProfileError.notFound(name)
        }

        // Never lose a hand-written [default]: keep it as its own profile first.
        let defaultExists = credentials.hasSection(Self.defaultName) || config.hasSection(Self.defaultName)
        let defaultIsManaged = profiles().contains { matchesDefault($0.name, credentials: credentials, config: config) }
        if defaultExists && !defaultIsManaged {
            let backup = uniqueName(Self.backupProfileName, credentials: credentials, config: config)
            credentials.setBody(credentials.body(of: Self.defaultName), of: backup)
            config.setBody(config.body(of: Self.defaultName), of: Self.configSection(for: backup))
        }

        credentials.setBody(credentials.body(of: name), of: Self.defaultName)
        config.setBody(config.body(of: configSection), of: Self.defaultName)

        try write(credentials, to: paths.credentials)
        try write(config, to: paths.config)
        try writeState(name)
    }

    public func add(_ profile: NewProfile) throws {
        let name = profile.name.trimmingCharacters(in: .whitespaces)
        try Self.validate(name: name)
        let keyId = profile.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = profile.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = profile.sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = profile.region.trimmingCharacters(in: .whitespaces)
        let output = profile.output.trimmingCharacters(in: .whitespaces)
        guard !keyId.isEmpty else { throw ProfileError.missingField("Access Key ID") }
        guard !secret.isEmpty else { throw ProfileError.missingField("Secret Access Key") }

        var credentials = read(paths.credentials)
        var config = read(paths.config)
        let configSection = Self.configSection(for: name)
        guard !credentials.hasSection(name), !config.hasSection(configSection) else {
            throw ProfileError.alreadyExists(name)
        }

        var credentialLines = ["aws_access_key_id = \(keyId)", "aws_secret_access_key = \(secret)"]
        if !token.isEmpty { credentialLines.append("aws_session_token = \(token)") }
        credentials.setBody(credentialLines, of: name)

        var configLines: [String] = []
        if !region.isEmpty { configLines.append("region = \(region)") }
        if !output.isEmpty { configLines.append("output = \(output)") }
        config.setBody(configLines, of: configSection)

        try write(credentials, to: paths.credentials)
        try write(config, to: paths.config)
    }

    public func remove(_ name: String) throws {
        var credentials = read(paths.credentials)
        var config = read(paths.config)
        let configSection = Self.configSection(for: name)
        guard credentials.hasSection(name) || config.hasSection(configSection) else {
            throw ProfileError.notFound(name)
        }
        credentials.removeSection(name)
        config.removeSection(configSection)
        try write(credentials, to: paths.credentials)
        try write(config, to: paths.config)
        if rememberedProfile() == name {
            try? fileManager.removeItem(at: paths.state)
        }
    }

    // MARK: Helpers

    public static func validate(name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@+"))
        guard !name.isEmpty else { throw ProfileError.missingField("Profile name") }
        guard name != defaultName, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProfileError.invalidName(name)
        }
    }

    /// Follows `source_profile` until it finds a profile with SSO settings.
    private func ssoInfo(for name: String, config: INIDocument, depth: Int = 0) -> SSOInfo? {
        guard depth < 10 else { return nil }
        let section = Self.configSection(for: name)
        if let session = config.value("sso_session", in: section) {
            let sessionSection = "sso-session \(session)"
            guard let startURL = config.value("sso_start_url", in: sessionSection) else { return nil }
            return SSOInfo(profile: name, sessionName: session, startURL: startURL,
                           region: config.value("sso_region", in: sessionSection))
        }
        if let startURL = config.value("sso_start_url", in: section) {
            return SSOInfo(profile: name, sessionName: nil, startURL: startURL,
                           region: config.value("sso_region", in: section))
        }
        if let source = config.value("source_profile", in: section), source != name {
            return ssoInfo(for: source, config: config, depth: depth + 1)
        }
        return nil
    }

    static func accountId(fromArn arn: String) -> String? {
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 4 && !parts[4].isEmpty ? String(parts[4]) : nil
    }

    static func roleName(fromArn arn: String) -> String? {
        arn.split(separator: "/").last.map(String.init)
    }

    static func configSection(for name: String) -> String {
        name == defaultName ? defaultName : "profile \(name)"
    }

    static func profileName(fromConfigSection section: String) -> String? {
        if section == defaultName { return defaultName }
        guard section.hasPrefix("profile ") else { return nil } // sso-session, services, …
        return String(section.dropFirst("profile ".count))
    }

    private func matchesDefault(_ name: String, credentials: INIDocument, config: INIDocument) -> Bool {
        func normalized(_ doc: INIDocument, _ section: String) -> [String: String] {
            Dictionary(doc.pairs(in: section).map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        }
        let defaultCredentials = normalized(credentials, Self.defaultName)
        let defaultConfig = normalized(config, Self.defaultName)
        guard !defaultCredentials.isEmpty || !defaultConfig.isEmpty else { return false }
        return defaultCredentials == normalized(credentials, name)
            && defaultConfig == normalized(config, Self.configSection(for: name))
    }

    private func uniqueName(_ base: String, credentials: INIDocument, config: INIDocument) -> String {
        var candidate = base
        var counter = 2
        while credentials.hasSection(candidate) || config.hasSection(Self.configSection(for: candidate)) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private func rememberedProfile() -> String? {
        guard let text = try? String(contentsOf: paths.state, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func read(_ url: URL) -> INIDocument {
        INIDocument(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    private func write(_ document: INIDocument, to url: URL) throws {
        let text = document.render()
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard text != existing, !(text.isEmpty && existing == nil) else { return }
        try prepareDirectory(for: url)
        try backupOnce(url)
        try Data(text.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func writeState(_ name: String) throws {
        try prepareDirectory(for: paths.state)
        try Data((name + "\n").utf8).write(to: paths.state, options: .atomic)
    }

    private func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        }
    }

    /// Keeps a pristine copy of each file from before AWSContext first touched it.
    private func backupOnce(_ url: URL) throws {
        let backup = url.appendingPathExtension("awscontext-backup")
        guard fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backup.path) else { return }
        try fileManager.copyItem(at: url, to: backup)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
    }
}
