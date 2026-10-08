import XCTest
@testable import AWSContextCore

final class INIDocumentTests: XCTestCase {
    func testRoundTripPreservesFormatting() {
        let text = """
        # my creds
        [default]
        aws_access_key_id = A
        ; comment
        [profile dev]
        region=eu-west-1
        s3 =
          max_concurrent_requests = 10

        """
        XCTAssertEqual(INIDocument(text: text).render(), text)
    }

    func testParsesSectionsAndPairs() {
        let doc = INIDocument(text: "[profile   dev]\nregion = eu-west-1\ns3 =\n  nested = 1\n")
        XCTAssertEqual(doc.sectionNames, ["profile dev"])
        XCTAssertEqual(doc.pairs(in: "profile dev").map(\.key), ["region", "s3"])
        XCTAssertEqual(doc.value("region", in: "profile dev"), "eu-west-1")
    }

    func testSetValueUpdatesInPlaceAndAppends() {
        var doc = INIDocument(text: "[a]\nx = 1\n\n[b]\ny = 2\n")
        doc.setValue("9", for: "x", in: "a")
        doc.setValue("3", for: "z", in: "a")
        doc.setValue("4", for: "w", in: "c")
        XCTAssertEqual(doc.render(), "[a]\nx = 9\nz = 3\n\n[b]\ny = 2\n\n[c]\nw = 4\n")
    }

    func testSetBodyEmptyRemovesSection() {
        var doc = INIDocument(text: "[a]\nx = 1\n\n[b]\ny = 2\n")
        doc.setBody([], of: "a")
        XCTAssertEqual(doc.render(), "[b]\ny = 2\n")
    }
}

final class ProfileStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ProfileStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ProfileStore(paths: AWSPaths(
            credentials: directory.appendingPathComponent("credentials"),
            config: directory.appendingPathComponent("config"),
            state: directory.appendingPathComponent("awscontext")
        ))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func testListsProfilesFromBothFiles() throws {
        try write("credentials", "[default]\naws_access_key_id = D\n[prod]\naws_access_key_id = P\naws_secret_access_key = S\n")
        try write("config", """
        [profile prod]
        region = us-east-1
        [profile sso-dev]
        sso_session = corp
        region = eu-west-1
        [sso-session corp]
        sso_start_url = https://example.awsapps.com/start
        """)
        let profiles = store.profiles()
        XCTAssertEqual(profiles.map(\.name), ["prod", "sso-dev"])
        XCTAssertEqual(profiles[0].kind, .accessKeys)
        XCTAssertEqual(profiles[0].region, "us-east-1")
        XCTAssertEqual(profiles[1].kind, .sso)
    }

    func testActivateCopiesIntoDefaultAndBacksUpHandWrittenDefault() throws {
        try write("credentials", "[default]\naws_access_key_id = ORIGINAL\n\n[prod]\naws_access_key_id = P\naws_secret_access_key = S\n")
        try write("config", "[default]\nregion = us-west-2\n\n[profile prod]\nregion = us-east-1\n")

        try store.activate("prod")

        XCTAssertEqual(store.activeProfileName(), "prod")
        let credentials = INIDocument(text: try read("credentials"))
        XCTAssertEqual(credentials.value("aws_access_key_id", in: "default"), "P")
        XCTAssertEqual(credentials.value("aws_access_key_id", in: "default-backup"), "ORIGINAL")
        let config = INIDocument(text: try read("config"))
        XCTAssertEqual(config.value("region", in: "default"), "us-east-1")
        XCTAssertEqual(config.value("region", in: "profile default-backup"), "us-west-2")
        XCTAssertEqual(try read("awscontext"), "prod\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("credentials.awscontext-backup").path))

        // Switching again must not create another backup.
        try store.activate("default-backup")
        try store.activate("prod")
        XCTAssertEqual(store.profiles().map(\.name), ["default-backup", "prod"])
    }

    func testActivatingSSOProfileClearsStaticDefaultKeys() throws {
        try write("credentials", "[keys]\naws_access_key_id = K\naws_secret_access_key = S\n")
        try write("config", "[profile keys]\nregion = us-east-1\n\n[profile sso]\nsso_session = corp\nsso_account_id = 1\n")
        try store.activate("keys")
        try store.activate("sso")
        XCTAssertFalse(INIDocument(text: try read("credentials")).hasSection("default"))
        XCTAssertEqual(INIDocument(text: try read("config")).value("sso_session", in: "default"), "corp")
        XCTAssertEqual(store.activeProfileName(), "sso")
    }

    func testAddAndRemove() throws {
        try store.add(NewProfile(name: "new", accessKeyId: "AK", secretAccessKey: "SK", region: "eu-west-1", output: "json"))
        XCTAssertEqual(try read("credentials"), "[new]\naws_access_key_id = AK\naws_secret_access_key = SK\n")
        XCTAssertEqual(try read("config"), "[profile new]\nregion = eu-west-1\noutput = json\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("credentials").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)

        XCTAssertThrowsError(try store.add(NewProfile(name: "new", accessKeyId: "A", secretAccessKey: "S")))
        XCTAssertThrowsError(try store.add(NewProfile(name: "bad name", accessKeyId: "A", secretAccessKey: "S")))
        XCTAssertThrowsError(try store.add(NewProfile(name: "default", accessKeyId: "A", secretAccessKey: "S")))

        try store.remove("new")
        XCTAssertTrue(store.profiles().isEmpty)
    }
}

final class CredentialParserTests: XCTestCase {
    func testParsesCredentialsBlock() {
        let parsed = CredentialParser.parse("[123_Admin]\naws_access_key_id=AK\naws_secret_access_key=SK\naws_session_token=TK\n")
        XCTAssertEqual(parsed, NewProfile(name: "123_Admin", accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TK"))
    }

    func testParsesShellExports() {
        let parsed = CredentialParser.parse("""
        export AWS_ACCESS_KEY_ID="AK"
        export AWS_SECRET_ACCESS_KEY="SK"
        $Env:AWS_SESSION_TOKEN='TK'
        set AWS_DEFAULT_REGION=eu-west-1
        """)
        XCTAssertEqual(parsed, NewProfile(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TK", region: "eu-west-1"))
    }

    func testParsesSTSJSON() {
        let parsed = CredentialParser.parse(#"{"Credentials": {"AccessKeyId": "AK", "SecretAccessKey": "SK", "SessionToken": "TK"}}"#)
        XCTAssertEqual(parsed, NewProfile(accessKeyId: "AK", secretAccessKey: "SK", sessionToken: "TK"))
    }

    func testReturnsNilForUnrelatedText() {
        XCTAssertNil(CredentialParser.parse("hello world"))
    }
}
