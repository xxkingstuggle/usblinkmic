import Darwin
import Foundation

public enum LogRedactor {
    private static let structuredValueRegexes: [NSRegularExpression] = [
        #"(?i)(\bserial\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#,
        #"(?i)(\btoken\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#,
        #"(?i)(\bpairingCode\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#,
        #"(?i)(\b(?:secret|sharedSecret|keyHex|pairingKey|audioToken|proof|nonce)\s*=\s*)(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;\}\]\)]+)"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }
    private static let jsonSecretRegex = try? NSRegularExpression(
        pattern: #"(?i)("(?:serial|token|pairingCode|secret|sharedSecret|keyHex|pairingKey|audioToken|proof|nonce)"\s*:\s*)"[^"\r\n]*""#
    )
    private static let homePathRegex = try? NSRegularExpression(
        pattern: #"(?<![\w])(/Users/[^/\s]+(?:/[^\s"'<>]*)?|~/[^\s"'<>]*)"#
    )
    private static let macAddressRegex = try? NSRegularExpression(
        pattern: #"(?i)(?<![a-f0-9:])(?:[a-f0-9]{2}:){5}[a-f0-9]{2}(?![a-f0-9:])"#
    )
    private static let ipv4Regex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![A-Za-z0-9_.])"#
    )
    private static let ipv6CandidateRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Fa-f0-9:.])[A-Fa-f0-9:.]+(?:%[A-Za-z0-9_.-]+)?(?![A-Fa-f0-9:.])"#
    )

    public static func redact(_ text: String) -> String {
        var result = text
        for regex in structuredValueRegexes {
            result = replacingMatches(in: result, regex: regex, template: "$1[REDACTED]")
        }
        result = replacingMatches(in: result, regex: jsonSecretRegex, template: #"$1"[REDACTED]""#)
        result = replacingMatches(in: result, regex: homePathRegex, template: "[HOME]")
        result = replacingMatches(in: result, regex: macAddressRegex, template: "[MAC]")
        result = replacingIPv4Addresses(in: result)
        result = replacingIPv6Addresses(in: result)
        return result
    }

    private static func replacingMatches(in text: String, regex: NSRegularExpression?, template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replacingIPv4Addresses(in text: String) -> String {
        guard let regex = ipv4Regex else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result), isIPv4Address(String(result[range])) else { continue }
            result.replaceSubrange(range, with: "[IP]")
        }
        return result
    }

    private static func replacingIPv6Addresses(in text: String) -> String {
        guard let regex = ipv6CandidateRegex else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
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
