import XCTest
@testable import AWSContextCore

/// Edge cases and end-to-end checks against the real AWS CLI (skipped when it isn't installed).
final class IntegrationTests: XCTestCase {
    private var directory: URL!
    private var paths: AWSPaths!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(".aws")
        paths = AWSPaths(
            credentials: directory.appendingPathComponent("credentials"),
            config: directory.appendingPathComponent("config"),
            state: directory.appendingPathComponent("awscontext")
        )
        store = ProfileStore(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Edge cases

    func testStartsFromNothing() throws {
        XCTAssertTrue(store.profiles().isEmpty)
        XCTAssertNil(store.activeProfileName())

        try store.add(NewProfile(name: "first", accessKeyId: "AK", secretAccessKey: "SK"))
        try store.activate("first")

        XCTAssertEqual(store.activeProfileName(), "first")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        // No config values were given, so no config file is needed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.config.path))
    }

    func testWindowsLineEndings() throws {
        try write(paths.credentials, "[a]\r\naws_access_key_id = A\r\naws_secret_access_key = S\r\n")
        XCTAssertEqual(store.profiles().map(\.name), ["a"])
        try store.activate("a")
        XCTAssertEqual(INIDocument(text: try read(paths.credentials)).value("aws_access_key_id", in: "default"), "A")
    }

    func testNestedSettingsAndCommentsSurviveSwitching() throws {
        let config = """
        # Managed by hand — keep this comment
        [profile big]
        region = eu-west-1
        s3 =
          max_concurrent_requests = 20

        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-west-1
        """
        try write(paths.config, config)
        try store.activate("big")

        let result = try read(paths.config)
        XCTAssertTrue(result.hasPrefix("# Managed by hand — keep this comment\n[profile big]"))
        XCTAssertTrue(result.contains("[default]\nregion = eu-west-1\ns3 =\n  max_concurrent_requests = 20\n"))
        XCTAssertTrue(result.contains("[sso-session corp]\nsso_start_url = https://example.awsapps.com/start"))
        XCTAssertEqual(store.profiles().map(\.name), ["big"]) // sso-session is not a profile
    }

    func testIdenticalProfilesUseRememberedChoice() throws {
        let keys = "aws_access_key_id = SAME\naws_secret_access_key = SAME\n"
        try write(paths.credentials, "[a]\n\(keys)\n[b]\n\(keys)")
        try store.activate("b")
        XCTAssertEqual(store.activeProfileName(), "b")
        try store.activate("a")
        XCTAssertEqual(store.activeProfileName(), "a")
    }

    func testEditingDefaultByHandShowsNoActiveProfile() throws {
        try write(paths.credentials, "[a]\naws_access_key_id = A\naws_secret_access_key = S\n")
        try store.activate("a")
        var doc = INIDocument(text: try read(paths.credentials))
        doc.setValue("CHANGED", for: "aws_access_key_id", in: "default")
        try write(paths.credentials, doc.render())
        XCTAssertNil(store.activeProfileName())
    }

    func testRemovingActiveProfileClearsState() throws {
        try store.add(NewProfile(name: "gone", accessKeyId: "A", secretAccessKey: "S"))
        try store.activate("gone")
        try store.remove("gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.state.path))
        XCTAssertNil(store.activeProfileName())
    }

    func testUnknownProfilesThrow() {
        XCTAssertThrowsError(try store.activate("nope")) { XCTAssertEqual($0 as? ProfileError, .notFound("nope")) }
        XCTAssertThrowsError(try store.remove("nope")) { XCTAssertEqual($0 as? ProfileError, .notFound("nope")) }
    }

    func testAddRequiresKeys() {
        XCTAssertThrowsError(try store.add(NewProfile(name: "x", secretAccessKey: "S"))) {
            XCTAssertEqual($0 as? ProfileError, .missingField("Access Key ID"))
        }
        XCTAssertThrowsError(try store.add(NewProfile(name: "x", accessKeyId: "A"))) {
            XCTAssertEqual($0 as? ProfileError, .missingField("Secret Access Key"))
        }
    }

    func testSecondBackupGetsUniqueName() throws {
        try write(paths.credentials, "[default]\naws_access_key_id = ONE\n\n[p]\naws_access_key_id = P\n")
        try store.activate("p")
        var doc = INIDocument(text: try read(paths.credentials))
        doc.setBody(["aws_access_key_id = TWO"], of: "default")
        try write(paths.credentials, doc.render())
        try store.activate("p")
        XCTAssertEqual(store.profiles().map(\.name), ["default-backup", "default-backup-2", "p"])
    }

    func testCredentialsAddedFromPortalPasteRoundTrip() throws {
        let clipboard = """
        [123456789012_AdministratorAccess]
        aws_access_key_id=ASIAEXAMPLE
        aws_secret_access_key=secret/with+chars=
        aws_session_token=IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ==
        """
        let parsed = try XCTUnwrap(CredentialParser.parse(clipboard))
        try store.add(parsed)
        try store.activate(parsed.name)
        let doc = INIDocument(text: try read(paths.credentials))
        XCTAssertEqual(doc.value("aws_secret_access_key", in: "default"), "secret/with+chars=")
        XCTAssertEqual(doc.value("aws_session_token", in: "default"),
                       "IQoJb3JpZ2luX2VjEJr//////////wEaCXVzLWVhc3QtMSJHMEUCIQ==")
    }

    // MARK: Real AWS CLI

    private func aws(_ arguments: String...) throws -> String {
        let candidates = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("AWS CLI not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "AWS_SHARED_CREDENTIALS_FILE": paths.credentials.path,
            "AWS_CONFIG_FILE": paths.config.path,
            "HOME": directory.deletingLastPathComponent().path,
            "PATH": "/usr/bin:/bin",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAWSCLIFollowsSwitches() throws {
        try write(paths.credentials, """
        [prod]
        aws_access_key_id = AKIAPROD
        aws_secret_access_key = prodsecret
        """)
        try write(paths.config, """
        [profile prod]
        region = us-east-1

        [profile dev-sso]
        sso_session = corp
        sso_account_id = 111111111111
        sso_role_name = Dev
        region = eu-central-1

        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-central-1
        """)
        try store.add(NewProfile(name: "staging", accessKeyId: "AKIASTAGING", secretAccessKey: "stagingsecret",
                                 region: "eu-west-1", output: "yaml"))

        try store.activate("prod")
        XCTAssertEqual(try aws("configure", "get", "aws_access_key_id"), "AKIAPROD")
        XCTAssertEqual(try aws("configure", "get", "region"), "us-east-1")

        try store.activate("staging")
        XCTAssertEqual(try aws("configure", "get", "aws_access_key_id"), "AKIASTAGING")
        XCTAssertEqual(try aws("configure", "get", "aws_secret_access_key"), "stagingsecret")
        XCTAssertEqual(try aws("configure", "get", "region"), "eu-west-1")
        XCTAssertEqual(try aws("configure", "get", "output"), "yaml")

        try store.activate("dev-sso")
        XCTAssertEqual(try aws("configure", "get", "region"), "eu-central-1")
        XCTAssertEqual(try aws("configure", "get", "sso_session"), "corp")
        // Static keys must be gone, otherwise they would shadow the SSO login.
        XCTAssertEqual(try aws("configure", "get", "aws_access_key_id"), "")
        // The CLI now resolves credentials through the SSO login (no token cached here).
        let identity = try aws("sts", "get-caller-identity")
        XCTAssertTrue(identity.contains("Token for corp does not exist"), identity)

        // Named profiles are untouched and still usable directly.
        XCTAssertEqual(try aws("configure", "get", "aws_access_key_id", "--profile", "prod"), "AKIAPROD")
    }
}
