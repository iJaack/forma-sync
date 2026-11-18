import XCTest
@testable import FormaSync

final class IngestConfigTests: XCTestCase {
    private let endpoint = "https://example.com/api/ingest/health"
    private let credentials = [
        "client_id": "unused",
        "client_secret": "unused",
        "bearer": "test-bearer"
    ]

    private func json(_ values: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    private func lines(_ values: [String: String]) -> String {
        values.map { "\($0.key.uppercased())=\($0.value)" }.joined(separator: "\n")
    }

    func testJSONWithExplicitURL() throws {
        var values = credentials
        values["url"] = endpoint
        let config = try XCTUnwrap(IngestConfig.parse(json(values)))
        XCTAssertEqual(config, IngestConfig(url: endpoint, clientId: "unused",
                                            clientSecret: "unused", bearer: "test-bearer"))
    }

    func testEnvironmentWithIngestURLAndCredentialAliases() {
        let text = """
        # Synthetic configuration
        INGEST_URL="https://example.com/api/ingest/health"
        CF_ACCESS_CLIENT_ID=unused
        CF_ACCESS_CLIENT_SECRET='unused'
        INGEST_BEARER=test-bearer
        """
        let config = IngestConfig.parse(text)
        XCTAssertEqual(config?.url, endpoint)
        XCTAssertEqual(config?.clientId, "unused")
        XCTAssertEqual(config?.clientSecret, "unused")
        XCTAssertEqual(config?.bearer, "test-bearer")
    }

    func testEnvironmentAcceptsURLKey() {
        var values = credentials
        values["url"] = endpoint
        XCTAssertEqual(IngestConfig.parse(lines(values))?.url, endpoint)
    }

    func testMissingURLIsRejectedInBothFormats() throws {
        XCTAssertNil(IngestConfig.parse(try json(credentials)))
        XCTAssertNil(IngestConfig.parse(lines(credentials)))
    }

    func testInvalidURLsAreRejectedInBothFormats() throws {
        for url in ["", " ", "http://example.com", "example.com", "/api/ingest/health",
                    "https://", "https:///api/ingest/health", "not a url"] {
            var values = credentials
            values["url"] = url
            XCTAssertNil(IngestConfig.parse(try json(values)), url)
            XCTAssertNil(IngestConfig.parse(lines(values)), url)
        }
    }

    func testSiteRootsAreNormalizedInBothFormats() throws {
        for url in ["https://example.com", "https://example.com/"] {
            var values = credentials
            values["url"] = url
            XCTAssertEqual(IngestConfig.parse(try json(values))?.url, endpoint)
            values.removeValue(forKey: "url")
            values["ingest_url"] = url
            XCTAssertEqual(IngestConfig.parse(lines(values))?.url, endpoint)
        }
    }

    func testExplicitPathsArePreservedInBothFormats() throws {
        for url in [endpoint, "https://example.com/custom/path",
                    "https://example.com/custom/", "https://example.com/custom%2Fpath?key=value#fragment"] {
            var values = credentials
            values["url"] = url
            XCTAssertEqual(IngestConfig.parse(try json(values))?.url, url)
            XCTAssertEqual(IngestConfig.parse(lines(values))?.url, url)
        }
    }

    func testRootNormalizationPreservesPortQueryAndFragment() throws {
        var values = credentials
        values["url"] = "https://example.com:8443/?key=value#fragment"
        XCTAssertEqual(IngestConfig.parse(try json(values))?.url,
                       "https://example.com:8443/api/ingest/health?key=value#fragment")
    }

    func testMissingAndEmptyCredentialsAreRejectedInBothFormats() throws {
        for key in credentials.keys {
            var values = credentials
            values["url"] = endpoint
            values.removeValue(forKey: key)
            XCTAssertNil(IngestConfig.parse(try json(values)), key)
            XCTAssertNil(IngestConfig.parse(lines(values)), key)
            for empty in ["", "   "] {
                values[key] = empty
                XCTAssertNil(IngestConfig.parse(try json(values)), key)
                XCTAssertNil(IngestConfig.parse(lines(values)), key)
            }
        }
    }

    func testSavedURLAndCredentialsAreUnchanged() {
        for url in [endpoint, "https://example.com", "https://example.com/custom/"] {
            for legacyURL: String? in [nil, "", "http://invalid.example", "https://legacy.example/ingest"] {
                XCTAssertEqual(IngestConfig.configurationForSavedCredentials(
                    url: url, clientId: "unused", clientSecret: "unused", bearer: "test-bearer",
                    legacyURL: legacyURL
                ), IngestConfig(url: url, clientId: "unused", clientSecret: "unused", bearer: "test-bearer"))
            }
        }
    }

    func testMissingSavedURLMigratesOnlyCompleteCredentials() throws {
        let migrated = try XCTUnwrap(IngestConfig.configurationForSavedCredentials(
            url: nil, clientId: "unused", clientSecret: "unused", bearer: "test-bearer", legacyURL: endpoint
        ))
        XCTAssertTrue(migrated.isComplete)
        XCTAssertEqual(migrated.url, endpoint)
        XCTAssertEqual(migrated.clientId, "unused")
        XCTAssertEqual(migrated.clientSecret, "unused")
        XCTAssertEqual(migrated.bearer, "test-bearer")
        // Once persisted, the same configuration takes the ordinary saved-URL path.
        XCTAssertEqual(IngestConfig.configurationForSavedCredentials(
            url: migrated.url, clientId: migrated.clientId,
            clientSecret: migrated.clientSecret, bearer: migrated.bearer, legacyURL: nil
        ), migrated)
    }

    func testMissingOrEmptyLegacyURLRequiresConfiguration() {
        for legacyURL: String? in [nil, "", "   "] {
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: nil, clientId: "unused", clientSecret: "unused", bearer: "test-bearer",
                legacyURL: legacyURL
            ))
        }
    }

    func testHTTPAndInvalidLegacyURLsRequireConfiguration() {
        for legacyURL in ["http://example.com/api/ingest/health", "example.com", "https://", "not a url"] {
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: nil, clientId: "unused", clientSecret: "unused", bearer: "test-bearer",
                legacyURL: legacyURL
            ))
        }
    }

    func testMissingSavedCredentialsNeverMigrate() {
        for absent: String? in [nil, ""] {
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: nil, clientId: absent, clientSecret: "unused", bearer: "test-bearer", legacyURL: endpoint
            ))
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: nil, clientId: "unused", clientSecret: absent, bearer: "test-bearer", legacyURL: endpoint
            ))
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: nil, clientId: "unused", clientSecret: "unused", bearer: absent, legacyURL: endpoint
            ))
        }
        XCTAssertNil(IngestConfig.configurationForSavedCredentials(
            url: nil, clientId: nil, clientSecret: nil, bearer: nil, legacyURL: endpoint
        ))
    }

    func testInvalidSavedURLDoesNotTriggerMigration() {
        for url in ["", "http://example.com", "not a url"] {
            XCTAssertNil(IngestConfig.configurationForSavedCredentials(
                url: url, clientId: "unused", clientSecret: "unused", bearer: "test-bearer", legacyURL: endpoint
            ))
        }
    }
}
