import Foundation
import Testing
@testable import Suggest

@Suite struct BangTests {
    @Test func prefixAndSuffixBangs() {
        #expect(Bangs.resolve("!yt lo-fi beats")?.url.absoluteString == "https://www.youtube.com/results?search_query=lo-fi%20beats")
        #expect(Bangs.resolve("swift actors !gh")?.bang.name == "GitHub")
        #expect(Bangs.resolve("!GH")?.url.absoluteString == "https://github.com")
    }

    @Test func notABang() {
        #expect(Bangs.resolve("hello world") == nil)
        #expect(Bangs.resolve("!nope cats") == nil)
        #expect(Bangs.resolve("!") == nil)
    }

    @Test func queryValuesAreEscaped() {
        let url = Bangs.resolve("!g a&b=c")?.url.absoluteString
        #expect(url == "https://www.google.com/search?q=a%26b%3Dc")
    }
}

@Suite struct CalculatorTests {
    @Test func sums() {
        #expect(Calculator.answer(for: "12*7+3")?.text == "87")
        #expect(Calculator.answer(for: "(1+2)^3")?.text == "27")
        #expect(Calculator.answer(for: "10/4")?.text == "2.5")
        #expect(Calculator.answer(for: "sqrt(16)")?.text == "4")
        #expect(Calculator.answer(for: "-3 + 5")?.text == "2")
    }

    @Test func percentagesAndUnits() {
        #expect(Calculator.answer(for: "15% of 80")?.text == "12")
        #expect(Calculator.answer(for: "5 km in mi")?.text == "3.107 mi")
        #expect(Calculator.answer(for: "212 f to c")?.text == "100 °C")
    }

    @Test func leavesSearchesAlone() {
        #expect(Calculator.answer(for: "2026") == nil)
        #expect(Calculator.answer(for: "gpt-4") == nil)
        #expect(Calculator.answer(for: "2024-11-11") == nil)
        #expect(Calculator.answer(for: "best pizza") == nil)
        #expect(Calculator.answer(for: "5 km in kg") == nil)
    }
}
