import Foundation
import Testing
@testable import NotTennaPodCore

struct StatisticsTextFormatterTests {
    private struct Row: Decodable { let locale: String, value: Int64, text: String; let zone: String? }
    private struct Fixture: Decodable { let now: Int64; let durations, sizes, dates: [Row] }
    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let url = try #require(Bundle.module.url(forResource: "statistics-format-runtime", withExtension: "json", subdirectory: "Fixtures"))
        #else
        let url = try #require(Bundle(for: StatisticsFormatterFixtureBundle.self)
            .url(forResource: "statistics-format-runtime", withExtension: "json"))
        #endif
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func durationsMatchActualOriginalAPKAcrossLocalesAndFloatBoundaries() throws {
        let data = try fixture()
        let labels = ["en-US": "hours", "de-DE": "Stunden", "fr-FR": "heures", "ar-EG": "ساعات", "ja-JP": "時間"]
        #expect(data.durations.count == 345)
        for row in data.durations {
            let formatter = StatisticsTextFormatter(locale: Locale(identifier: row.locale))
            #expect(formatter.duration(seconds: row.value, hoursLabel: try #require(labels[row.locale])) == row.text,
                    "\(row.locale) seconds=\(row.value)")
        }
    }

    @Test func fileSizesMatchActualAndroidPrecisionUnitsAndSpaces() throws {
        let data = try fixture()
        #expect(data.sizes.count == 345)
        for row in data.sizes where row.value != .min {
            let formatter = StatisticsTextFormatter(locale: Locale(identifier: row.locale))
            #expect(formatter.fileSize(bytes: row.value) == row.text, "\(row.locale) bytes=\(row.value)")
        }
        // The retained Android Long.MIN_VALUE rows demonstrate signed negation
        // overflow. Correct magnitude/sign, rather than reproducing that defect.
        #expect(data.sizes.filter { $0.value == .min }.count == 5)
        let english = StatisticsTextFormatter(locale: Locale(identifier: "en-US"))
        #expect(english.fileSize(bytes: .min) == "-9223 PB")
    }

    @Test func abbreviatedDatesMatchOriginalAppForYearZoneAndLocale() throws {
        let data = try fixture()
        #expect(data.dates.count == 135)
        for row in data.dates {
            let zone = try #require(row.zone.flatMap(TimeZone.init(identifier:)))
            let formatter = StatisticsTextFormatter(locale: Locale(identifier: row.locale), timeZone: zone,
                now: Date(timeIntervalSince1970: Double(data.now) / 1000))
            #expect(formatter.abbreviatedDate(Date(timeIntervalSince1970: Double(row.value) / 1000)) == row.text,
                    "\(row.locale) \(zone.identifier) date=\(row.value)")
            #expect(formatter.abbreviatedDate(nil).isEmpty)
        }
    }
}

#if !SWIFT_PACKAGE
private final class StatisticsFormatterFixtureBundle: NSObject {}
#endif
