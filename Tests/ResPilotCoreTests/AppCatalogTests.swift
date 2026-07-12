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
        #expect(Set(names) == ["Steam", "Rockstar Games Launcher"])
        #expect(AppCatalog.popular.count == 2)
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
