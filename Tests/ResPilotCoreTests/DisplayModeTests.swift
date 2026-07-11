import Testing
@testable import ResPilotCore

@Suite struct DisplayModeInfoTests {
    @Test func isHiDPITrueWhenBackingIsExactlyDoubleThePointSize() {
        #expect(Fixtures.mode(w: 1440, h: 900, hiDPI: true).isHiDPI)
    }

    @Test func isHiDPIFalseForA1xBackingScale() {
        #expect(!Fixtures.mode(w: 1440, h: 900, hiDPI: false).isHiDPI)
    }

    @Test func isHiDPIFalseForNonIntegerScaleFactors() {
        // Backing 2880x1800 at point 1600x1000 is a 1.8x scale, not Retina.
        let mode = DisplayModeInfo(pointWidth: 1600, pointHeight: 1000, pixelWidth: 2880, pixelHeight: 1800, refreshRateHz: 60)
        #expect(!mode.isHiDPI)
    }

    @Test func descriptionIncludesHiDPIAndRefreshRateWhenPresent() {
        let text = Fixtures.mode(w: 1920, h: 1080, hiDPI: true, hz: 120).description
        #expect(text.contains("1920x1080"))
        #expect(text.contains("HiDPI"))
        #expect(text.contains("@120Hz"))
        #expect(text.contains("3840x2160"))
    }

    @Test func descriptionOmitsRefreshRateWhenZero() {
        let mode = DisplayModeInfo(pointWidth: 1920, pointHeight: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRateHz: 0)
        #expect(!mode.description.contains("@"))
    }
}

@Suite struct DisplayTargetTests {
    @Test func leaveUnchangedSentinelReportsIsLeaveUnchanged() {
        #expect(DisplayTarget.leaveUnchanged.isLeaveUnchanged)
    }

    @Test func aRealTargetIsNotLeaveUnchanged() {
        #expect(!DisplayTarget(pointWidth: 1920, pointHeight: 1080, hiDPI: true).isLeaveUnchanged)
    }
}

@Suite struct DisplayModeMatcherTests {
    private static let modes = [
        Fixtures.mode(w: 1440, h: 900, hiDPI: false),
        Fixtures.mode(w: 1440, h: 900, hiDPI: true),
        Fixtures.mode(w: 1920, h: 1080, hiDPI: false),
    ]

    @Test func matchesOnExactWidthHeightAndHiDPITogether() {
        let target = DisplayTarget(pointWidth: 1440, pointHeight: 900, hiDPI: true)
        let match = DisplayModeMatcher.match(target: target, in: Self.modes)
        #expect(match?.isHiDPI == true)
        #expect(match?.pointWidth == 1440)
    }

    @Test func distinguishesHiDPIFromNonHiDPIAtTheSamePointSize() {
        let target = DisplayTarget(pointWidth: 1440, pointHeight: 900, hiDPI: false)
        #expect(DisplayModeMatcher.match(target: target, in: Self.modes)?.isHiDPI == false)
    }

    @Test func returnsNilWhenNoModeMatches() {
        let target = DisplayTarget(pointWidth: 2560, pointHeight: 1440, hiDPI: true)
        #expect(DisplayModeMatcher.match(target: target, in: Self.modes) == nil)
    }
}
