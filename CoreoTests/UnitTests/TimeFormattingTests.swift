// TimeFormattingTests.swift
// CoreoTests
//
// Unit tests for time formatting utilities.

@testable import Coreo
import XCTest

final class TimeFormattingTests: XCTestCase {
    // MARK: - format (M:SS.ff)

    func testFormatTypicalValue() {
        XCTAssertEqual(TimeFormatting.format(83.45), "1:23.45")
    }

    func testFormatZeroSeconds() {
        XCTAssertEqual(TimeFormatting.format(0), "0:00.00")
    }

    func testFormatSubSecond() {
        XCTAssertEqual(TimeFormatting.format(0.75), "0:00.75")
    }

    func testFormatExactMinute() {
        XCTAssertEqual(TimeFormatting.format(60.0), "1:00.00")
    }

    func testFormatLargeValue() {
        // 7200 seconds = 120 minutes
        XCTAssertEqual(TimeFormatting.format(7200.0), "120:00.00")
    }

    func testFormatNegativeShowsZero() {
        XCTAssertEqual(TimeFormatting.format(-5.0), "0:00.00")
    }

    func testFormatNaN() {
        XCTAssertEqual(TimeFormatting.format(Double.nan), "--:--.--")
    }

    func testFormatInfinity() {
        XCTAssertEqual(TimeFormatting.format(Double.infinity), "--:--.--")
    }

    func testFormatNegativeInfinity() {
        XCTAssertEqual(TimeFormatting.format(-Double.infinity), "--:--.--")
    }

    // MARK: - formatShort (M:SS)

    func testFormatShortTypicalValue() {
        XCTAssertEqual(TimeFormatting.formatShort(83.45), "1:23")
    }

    func testFormatShortZero() {
        XCTAssertEqual(TimeFormatting.formatShort(0), "0:00")
    }

    func testFormatShortExactMinute() {
        XCTAssertEqual(TimeFormatting.formatShort(120.0), "2:00")
    }

    func testFormatShortNegativeShowsZero() {
        XCTAssertEqual(TimeFormatting.formatShort(-10.0), "0:00")
    }

    func testFormatShortNaN() {
        XCTAssertEqual(TimeFormatting.formatShort(Double.nan), "--:--")
    }

    func testFormatShortInfinity() {
        XCTAssertEqual(TimeFormatting.formatShort(Double.infinity), "--:--")
    }

    // MARK: - formatLong (H:MM:SS)

    func testFormatLongTypicalValue() {
        // 3661 seconds = 1 hour, 1 minute, 1 second
        XCTAssertEqual(TimeFormatting.formatLong(3661.0), "1:01:01")
    }

    func testFormatLongZero() {
        XCTAssertEqual(TimeFormatting.formatLong(0), "0:00:00")
    }

    func testFormatLongUnderOneHour() {
        XCTAssertEqual(TimeFormatting.formatLong(83.45), "0:01:23")
    }

    func testFormatLongExactHour() {
        XCTAssertEqual(TimeFormatting.formatLong(3600.0), "1:00:00")
    }

    func testFormatLongMultipleHours() {
        // 36000 = 10 hours
        XCTAssertEqual(TimeFormatting.formatLong(36000.0), "10:00:00")
    }

    func testFormatLongNegativeShowsZero() {
        XCTAssertEqual(TimeFormatting.formatLong(-100.0), "0:00:00")
    }

    func testFormatLongNaN() {
        XCTAssertEqual(TimeFormatting.formatLong(Double.nan), "--:--:--")
    }

    func testFormatLongInfinity() {
        XCTAssertEqual(TimeFormatting.formatLong(Double.infinity), "--:--:--")
    }
}
