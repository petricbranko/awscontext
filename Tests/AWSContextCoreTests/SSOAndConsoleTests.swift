import XCTest
@testable import AWSContextCore

final class SSOAndConsoleTests: XCTestCase {
    private var directory: URL!
    private var paths: AWSPaths!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sso/cache"),
                                                withIntermediateDirectories: true)
        paths = AWSPaths(
            credentials: directory.appendingPathComponent("credentials"),
            config: directory.appendingPathComponent("config"),
            state: directory.appendingPathComponent("awscontext")
        )
        store = ProfileStore(paths: paths)
        try """
        [profile dev]
        sso_session = corp
        sso_account_id = 111111111111
        sso_role_name = Developer
        region = eu-central-1

        [profile legacy]
        sso_start_url = https://legacy.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 222222222222
        sso_role_name = ReadOnly

        [profile admin]
        role_arn = arn:aws:iam::333333333333:role/OrgAdmin
        source_profile = dev

        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-central-1
        """.write(to: paths.config, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeToken(_ fileName: String, _ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: paths.ssoCache.appendingPathComponent(fileName))
    }

    // MARK: Profile details

    func testResolvesSSOSettingsAccountAndRole() throws {
        let profiles = Dictionary(uniqueKeysWithValues: store.profiles().map { ($0.name, $0) })

        let dev = try XCTUnwrap(profiles["dev"])
        XCTAssertEqual(dev.kind, .sso)
        XCTAssertEqual(dev.accountId, "111111111111")
        XCTAssertEqual(dev.roleName, "Developer")
        XCTAssertEqual(dev.sso, SSOInfo(profile: "dev", sessionName: "corp",
                                        startURL: "https://example.awsapps.com/start", region: "eu-central-1"))

        let legacy = try XCTUnwrap(profiles["legacy"])
        XCTAssertEqual(legacy.sso?.sessionName, nil)
        XCTAssertEqual(legacy.sso?.startURL, "https://legacy.awsapps.com/start")

        // A role assumed from an SSO profile inherits its login, but has its own account and role.
        let admin = try XCTUnwrap(profiles["admin"])
        XCTAssertEqual(admin.kind, .role)
        XCTAssertEqual(admin.accountId, "333333333333")
        XCTAssertEqual(admin.roleName, "OrgAdmin")
        XCTAssertEqual(admin.sso?.profile, "dev")
    }

    func testSourceProfileLoopDoesNotHang() throws {
        try "[profile a]\nsource_profile = b\nrole_arn = arn:aws:iam::1:role/x\n[profile b]\nsource_profile = a\nrole_arn = arn:aws:iam::1:role/y\n"
            .write(to: paths.config, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.profiles().compactMap(\.sso).count, 0)
    }

    // MARK: SSO token cache

    func testCacheFileNamesMatchTheAWSCLI() {
        let session = SSOInfo(profile: "dev", sessionName: "corp", startURL: "https://example.awsapps.com/start")
        XCTAssertEqual(SSOTokenCache.cacheFileName(for: session), "ee0bfd2552fbd840c02cc48b6e823320543c450f.json")
        let legacy = SSOInfo(profile: "x", sessionName: nil, startURL: "https://example.awsapps.com/start")
        XCTAssertEqual(SSOTokenCache.cacheFileName(for: legacy), "e8be5486177c5b5392bd9aa76563515b29358e6e.json")
    }

    func testSessionStatus() throws {
        let info = try XCTUnwrap(store.profiles().first { $0.name == "dev" }?.sso)
        let file = SSOTokenCache.cacheFileName(for: info)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func status() -> SSOSessionStatus { SSOTokenCache.status(for: info, cacheDirectory: paths.ssoCache, now: now) }

        XCTAssertEqual(status(), .signedOut)

        try writeToken(file, ["accessToken": "x", "expiresAt": "2027-01-15T10:00:00Z"])
        XCTAssertEqual(status(), .valid(until: SSOTokenCache.parseDate("2027-01-15T10:00:00Z")!))

        try writeToken(file, ["accessToken": "x", "expiresAt": "2026-01-01T00:00:00Z"])
        XCTAssertEqual(status(), .expired)

        try writeToken(file, ["accessToken": "x", "expiresAt": "2026-01-01T00:00:00Z",
                              "refreshToken": "r", "registrationExpiresAt": "2027-06-01T00:00:00Z"])
        XCTAssertEqual(status(), .refreshable)

        try writeToken(file, ["accessToken": "x", "expiresAt": "2026-01-01T00:00:00Z",
                              "refreshToken": "r", "registrationExpiresAt": "2026-06-01T00:00:00Z"])
        XCTAssertEqual(status(), .expired)
    }

    func testParsesCLIDateFormats() {
        XCTAssertNotNil(SSOTokenCache.parseDate("2026-10-08T18:00:00Z"))
        XCTAssertNotNil(SSOTokenCache.parseDate("2026-10-08T18:00:00UTC"))
        XCTAssertNotNil(SSOTokenCache.parseDate("2026-10-08T18:00:00.123Z"))
        XCTAssertNil(SSOTokenCache.parseDate("tomorrow"))
    }

    // MARK: Console URLs

    func testConsoleURL() {
        XCTAssertEqual(ConsoleSignIn.consoleURL(region: "eu-west-1").absoluteString,
                       "https://eu-west-1.console.aws.amazon.com/console/home?region=eu-west-1")
        XCTAssertEqual(ConsoleSignIn.consoleURL(region: nil).absoluteString,
                       "https://console.aws.amazon.com/console/home")
    }

    func testSSOShortcutURL() {
        let url = ConsoleSignIn.ssoShortcutURL(
            startURL: "https://example.awsapps.com/start/#", accountId: "111111111111", roleName: "Developer",
            destination: ConsoleSignIn.consoleURL(region: "eu-west-1"))
        XCTAssertEqual(url?.absoluteString,
                       "https://example.awsapps.com/start/#/console?account_id=111111111111&role_name=Developer"
                       + "&destination=https%3A%2F%2Feu-west-1.console.aws.amazon.com%2Fconsole%2Fhome%3Fregion%3Deu-west-1")
    }

    func testShortcutIsUsedForSSOProfilesWithoutTheCLI() async throws {
        let dev = try XCTUnwrap(store.profiles().first { $0.name == "dev" })
        let url = try await ConsoleSignIn.url(for: dev, cli: AWSCLI(paths: paths, executable: nil))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://example.awsapps.com/start/#/console?account_id=111111111111&role_name=Developer"))
    }

    func testFederationLoginURLEscapesEverything() {
        let url = ConsoleSignIn.loginURL(signinToken: "a+b/c=",
                                         destination: ConsoleSignIn.consoleURL(region: "us-east-1"))
        XCTAssertEqual(url.absoluteString,
                       "https://signin.aws.amazon.com/federation?Action=login&Issuer=AWSContext"
                       + "&Destination=https%3A%2F%2Fus-east-1.console.aws.amazon.com%2Fconsole%2Fhome%3Fregion%3Dus-east-1"
                       + "&SigninToken=a%2Bb%2Fc%3D")
    }

    func testParsesCredentialJSON() {
        XCTAssertEqual(
            ConsoleSignIn.parseCredentials(#"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"SK","SessionToken":"TK"}"#),
            TemporaryCredentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TK"))
        XCTAssertEqual(
            ConsoleSignIn.parseCredentials(#"{"Credentials":{"AccessKeyId":"AK","SecretAccessKey":"SK","SessionToken":"TK"}}"#),
            TemporaryCredentials(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TK"))
        XCTAssertEqual(ConsoleSignIn.parseCredentials(#"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"SK"}"#)?.sessionToken, "")
        XCTAssertNil(ConsoleSignIn.parseCredentials("nope"))
    }

    // MARK: AWS CLI

    func testMissingCLIIsReported() async {
        do {
            _ = try await AWSCLI(paths: paths, executable: nil).run(["--version"])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .notInstalled)
        }
    }

    func testCLIUsesOurFilesAndReportsErrors() async throws {
        let cli = AWSCLI(paths: paths)
        guard cli.executable != nil else { throw XCTSkip("AWS CLI not installed") }
        try "[keys]\naws_access_key_id = AKIATEST\naws_secret_access_key = secret\naws_session_token = token\n"
            .write(to: paths.credentials, atomically: true, encoding: .utf8)

        let output = try await cli.run(["configure", "export-credentials", "--profile", "keys", "--format", "process"])
        XCTAssertEqual(ConsoleSignIn.parseCredentials(output),
                       TemporaryCredentials(accessKeyId: "AKIATEST", secretAccessKey: "secret", sessionToken: "token"))

        do {
            _ = try await cli.run(["configure", "get", "region", "--profile", "does-not-exist"])
            XCTFail("expected an error")
        } catch AWSCLIError.failed(let message) {
            XCTAssertTrue(message.contains("does-not-exist"), message)
        }
    }

    func testCancellingCLI() async throws {
        let cli = AWSCLI(paths: paths, executable: URL(fileURLWithPath: "/bin/sleep"))
        do {
            _ = try await cli.run(["30"]) { $0.terminate() }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? AWSCLIError, .cancelled)
        }
    }
}
