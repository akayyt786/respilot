import CoreGraphics
import Foundation

/// A single addressable macOS display mode. Value type so matching/selection
/// logic can be unit tested without touching real CoreGraphics state.
public struct DisplayModeInfo: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    /// Point (logical) width — what layout/AppKit see.
    public let pointWidth: Int
    /// Point (logical) height.
    public let pointHeight: Int
    /// Backing pixel width — the physical resolution being scanned out.
    public let pixelWidth: Int
    /// Backing pixel height.
    public let pixelHeight: Int
    public let refreshRateHz: Double

    public init(pointWidth: Int, pointHeight: Int, pixelWidth: Int, pixelHeight: Int, refreshRateHz: Double) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRateHz = refreshRateHz
    }

    /// True when this mode renders at 2x backing scale ("Retina"/HiDPI).
    public var isHiDPI: Bool {
        pixelWidth == pointWidth * 2 && pixelHeight == pointHeight * 2
    }

    public var description: String {
        let hz = refreshRateHz > 0 ? " @\(Int(refreshRateHz))Hz" : ""
        return "\(pointWidth)x\(pointHeight)\(isHiDPI ? " HiDPI" : "")\(hz) (backing \(pixelWidth)x\(pixelHeight))"
    }
}

/// What a profile wants the display to look like while its game runs.
public struct DisplayTarget: Equatable, Sendable, Codable {
    public let pointWidth: Int
    public let pointHeight: Int
    public let hiDPI: Bool

    public init(pointWidth: Int, pointHeight: Int, hiDPI: Bool) {
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hiDPI = hiDPI
    }

    /// Sentinel meaning "leave the display exactly as it is" — no mode
    /// switch, only the Wine-side registry keys change.
    public static let leaveUnchanged = DisplayTarget(pointWidth: 0, pointHeight: 0, hiDPI: false)
    public var isLeaveUnchanged: Bool { pointWidth == 0 && pointHeight == 0 }
}

public enum DisplayModeError: Error, LocalizedError, Equatable {
    case noSuchDisplay(CGDirectDisplayID)
    case noMatchingMode(DisplayTarget, available: [DisplayModeInfo])
    case setModeFailed(CGError.RawValue)

    public var errorDescription: String? {
        switch self {
        case .noSuchDisplay(let id):
            return "No display with id \(id)."
        case .noMatchingMode(let target, let available):
            let want = "\(target.pointWidth)x\(target.pointHeight)\(target.hiDPI ? " HiDPI" : "")"
            let have = available.map(\.description).joined(separator: ", ")
            return "No display mode matching \(want). Available: \(have)"
        case .setModeFailed(let code):
            return "CGDisplaySetDisplayMode failed with CGError \(code)."
        }
    }
}

/// Abstraction over CoreGraphics so mode-selection logic is testable without
/// touching a real screen, and so a fake can be swapped in for orchestration
/// tests. `CoreGraphicsDisplayModeProvider` is the real implementation.
public protocol DisplayModeProviding: Sendable {
    var mainDisplayID: CGDirectDisplayID { get }
    func currentMode(display: CGDirectDisplayID) throws -> DisplayModeInfo
    func availableModes(display: CGDirectDisplayID) throws -> [DisplayModeInfo]
    func setMode(_ mode: DisplayModeInfo, display: CGDirectDisplayID) throws
}

/// Pure selection logic — given what's on the screen right now, pick the
/// concrete mode that satisfies a profile's `DisplayTarget`. Kept free of
/// CoreGraphics so it's exercised directly in unit tests.
public enum DisplayModeMatcher {
    public static func match(target: DisplayTarget, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        modes.first {
            $0.pointWidth == target.pointWidth &&
            $0.pointHeight == target.pointHeight &&
            $0.isHiDPI == target.hiDPI
        }
    }
}

/// Real CoreGraphics-backed implementation. Every call re-queries live
/// display state rather than caching `CGDisplayMode` refs, so there's no
/// stale-handle risk between "list" and "apply".
public final class CoreGraphicsDisplayModeProvider: DisplayModeProviding {
    public init() {}

    public var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    public func currentMode(display: CGDirectDisplayID) throws -> DisplayModeInfo {
        guard let mode = CGDisplayCopyDisplayMode(display) else {
            throw DisplayModeError.noSuchDisplay(display)
        }
        return DisplayModeInfo(
            pointWidth: mode.width,
            pointHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRateHz: mode.refreshRate
        )
    }

    public func availableModes(display: CGDirectDisplayID) throws -> [DisplayModeInfo] {
        // kCGDisplayShowDuplicateLowResolutionModes surfaces both the HiDPI
        // and non-HiDPI variant at the same point size — without it macOS
        // hides the scaled/non-Retina duplicates entirely.
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
            throw DisplayModeError.noSuchDisplay(display)
        }
        var seen = Set<DisplayModeInfo>()
        var result: [DisplayModeInfo] = []
        for mode in cgModes {
            let info = DisplayModeInfo(
                pointWidth: mode.width,
                pointHeight: mode.height,
                pixelWidth: mode.pixelWidth,
                pixelHeight: mode.pixelHeight,
                refreshRateHz: mode.refreshRate
            )
            if seen.insert(info).inserted {
                result.append(info)
            }
        }
        return result
    }

    public func setMode(_ mode: DisplayModeInfo, display: CGDirectDisplayID) throws {
        let options: CFDictionary = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let cgModes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
            throw DisplayModeError.noSuchDisplay(display)
        }
        guard let target = cgModes.first(where: {
            $0.width == mode.pointWidth && $0.height == mode.pointHeight &&
            $0.pixelWidth == mode.pixelWidth && $0.pixelHeight == mode.pixelHeight
        }) else {
            throw DisplayModeError.noMatchingMode(
                DisplayTarget(pointWidth: mode.pointWidth, pointHeight: mode.pointHeight, hiDPI: mode.isHiDPI),
                available: try availableModes(display: display)
            )
        }
        var config: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&config)
        guard beginResult == .success, let config else {
            throw DisplayModeError.setModeFailed(beginResult.rawValue)
        }
        let setResult = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard setResult == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayModeError.setModeFailed(setResult.rawValue)
        }
        let completeResult = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeResult == .success else {
            throw DisplayModeError.setModeFailed(completeResult.rawValue)
        }
    }
}
