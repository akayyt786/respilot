import Foundation
import Testing
@testable import ResPilotCore

@Suite struct AppCatalogTests {
    @Test func wineBottleKindResolvesToDirectDownloadURL() {
        let url = URL(string: "https://example.com/installer.exe")!
        let app = CatalogApp(
            name: "Test App",
            vendor: "Test Vendor",
            downloadPageURL: URL(string: "https://example.com")!,
            directDownloadURL: url,
            recommendedVerbs: []
        )

        #expect(app.resolvedDirectDownloadURL == url)
    }

    @Test func wineBottleKindWithNoDirectDownloadURLResolvesToNil() {
        let app = CatalogApp(
            name: "Test App",
            vendor: "Test Vendor",
            downloadPageURL: URL(string: "https://example.com")!,
            recommendedVerbs: []
        )

        #expect(app.resolvedDirectDownloadURL == nil)
    }

    /// `#if arch(...)` is resolved at compile time — this test binary is
    /// only ever built for one architecture, so it can only exercise
    /// whichever branch this machine's toolchain actually compiles. That's
    /// an inherent, acceptable limit of testing platform-conditional code;
    /// the assertion below matches the architecture this suite is running
    /// on rather than guessing.
    @Test func nativeMacAppKindResolvesToTheCurrentArchitecturesURL() {
        let arm64URL = URL(string: "https://example.com/app-arm64.zip")!
        let x64URL = URL(string: "https://example.com/app-x64.zip")!
        let app = CatalogApp(
            name: "Test App",
            vendor: "Test Vendor",
            downloadPageURL: URL(string: "https://example.com")!,
            recommendedVerbs: [],
            installKind: .nativeMacApp(arm64URL: arm64URL, x64URL: x64URL)
        )

        #if arch(arm64)
        #expect(app.resolvedDirectDownloadURL == arm64URL)
        #else
        #expect(app.resolvedDirectDownloadURL == x64URL)
        #endif
    }

    @Test func catalogIncludesTheExpectedApps() {
        let names = AppCatalog.popular.map(\.name)
        #expect(names.contains("Steam"))
        #expect(names.contains("Rockstar Games Launcher"))
        #expect(names.contains { $0.localizedCaseInsensitiveContains("Epic") })
    }

    @Test func epicEntryIsANativeMacAppNotAWineBottle() throws {
        let epic = try #require(AppCatalog.popular.first { $0.name.localizedCaseInsensitiveContains("Epic") })
        guard case .nativeMacApp = epic.installKind else {
            Issue.record("Expected Epic catalog entry to use .nativeMacApp, since Epic's own Windows installer doesn't complete under Wine.")
            return
        }
        #expect(epic.resolvedDirectDownloadURL != nil)
        #expect(epic.recommendedVerbs.isEmpty)
    }

    @Test func steamAndRockstarAreStillWineBottleApps() {
        for name in ["Steam", "Rockstar Games Launcher"] {
            guard let app = AppCatalog.popular.first(where: { $0.name == name }) else {
                Issue.record("Missing catalog entry: \(name)")
                continue
            }
            #expect(app.installKind == .wineBottle)
        }
    }
}
