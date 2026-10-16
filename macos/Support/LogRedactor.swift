import Darwin
import Foundation

public enum LogRedactor {
    private static let structuredValuePatterns = [
        #"(?i)(\bserial\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#,
        #"(?i)(\btoken\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#,
        #"(?i)(\bpairingCode\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#
    ]
    private static let homePathPattern = #"(?<![\w])(/Users/[^/\s]+(?:/[^\s"'<>]*)?|~/[^\s"'<>]*)"#
    private static let ipv4Pattern = #"(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_.])"#
    private static let ipv6CandidatePattern = #"(?<![A-Fa-f0-9:.])[A-Fa-f0-9:.]+(?:%[A-Za-z0-9_.-]+)?(?![A-Fa-f0-9:.])"#

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in structuredValuePatterns {
            result = replacingMatches(in: result, pattern: pattern, template: "$1[REDACTED]")
        }
        result = replacingMatches(in: result, pattern: homePathPattern, template: "[HOME]")
        result = replacingMatches(in: result, pattern: #"(?i)(?<![a-f0-9:])(?:[a-f0-9]{2}:){5}[a-f0-9]{2}(?![a-f0-9:])"#, template: "[MAC]")
        result = replacingIPv4Addresses(in: result)
        result = replacingIPv6Addresses(in: result)
        return result
    }

    private static func replacingMatches(in text: String, pattern: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replacingIPv4Addresses(in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: ipv4Pattern) else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), isIPv4Address(String(result[range])) else { continue }
            result.replaceSubrange(range, with: "[IP]")
        }
        return result
    }

    private static func replacingIPv6Addresses(in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: ipv6CandidatePattern) else { return text }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let candidate = String(result[range])
            guard candidate.contains(":"), isIPv6Address(candidate) else { continue }
            result.replaceSubrange(range, with: "[IP]")
        }
        return result
    }

    private static func isIPv6Address(_ value: String) -> Bool {
        let address = value.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        var parsed = in6_addr()
        return address.withCString { inet_pton(AF_INET6, $0, &parsed) == 1 }
    }
}
