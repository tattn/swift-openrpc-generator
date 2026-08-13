import Testing

@testable import OpenRPCGeneratorKit

@Suite struct RenderHelpersTests {
    @Test(
        "String literals escape quotes, backslashes, and control characters",
        arguments: [
            (input: #"say "hi""#, expected: #""say \"hi\"""#),
            (input: #"a\b"#, expected: #""a\\b""#),
            (input: "line1\nline2", expected: #""line1\nline2""#),
            (input: "a\rb", expected: #""a\rb""#),
            (input: "a\tb", expected: #""a\tb""#),
            (input: "a\0b", expected: #""a\0b""#),
            (input: "bell\u{07}", expected: #""bell\u{7}""#),
            (input: "escape\u{1B}[0m", expected: #""escape\u{1B}[0m""#),
            (input: "plain ascii and 日本語 ✅", expected: "\"plain ascii and 日本語 ✅\""),
        ]
    )
    func swiftStringLiteral(input: String, expected: String) {
        #expect(OpenRPCGeneratorKit.swiftStringLiteral(input) == expected)
    }
}
