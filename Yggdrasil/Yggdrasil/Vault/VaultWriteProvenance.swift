import Foundation
import YggdrasilCore

enum VaultWriteProvenance {
    typealias TimestampProvider = @Sendable () throws -> String

    private enum InjectionError: LocalizedError {
        case unsafeFrontmatter

        var errorDescription: String? {
            "The note frontmatter could not be tagged without changing foreign YAML."
        }
    }

    static func applying(
        to text: String,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> String {
        do {
            return try injecting(into: text, writtenAt: timestampProvider())
        } catch {
            let sanitization = YAMLProvenanceSanitizer.sanitizingFallback(text)
            logFailure(
                error,
                relativePath: relativePath,
                neutralizedStaleAttribution: sanitization.neutralizedStaleAttribution,
                failureLogger: failureLogger
            )
            return sanitization.text
        }
    }

    private static func injecting(into text: String, writtenAt: String) throws -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        let provenanceLines = [
            "agent_provenance:",
            "  author: bifrost-ios",
            "  written_at: \(writtenAt)",
            "  origin: direct-fs"
        ]

        guard text.hasPrefix("---\(newline)") else {
            return (["---"] + provenanceLines + ["---", "", text]).joined(separator: newline)
        }

        var lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw InjectionError.unsafeFrontmatter
        }

        let candidates = lines[1..<closingIndex].indices.filter { index in
            let line = lines[index]
            guard line.first?.isWhitespace != true else { return false }
            return line.contains("agent_provenance")
        }
        guard candidates.count <= 1 else { throw InjectionError.unsafeFrontmatter }

        if let startIndex = candidates.first {
            guard lines[startIndex].hasPrefix("agent_provenance:") else {
                throw InjectionError.unsafeFrontmatter
            }
            let remainder = lines[startIndex].dropFirst("agent_provenance:".count)
                .trimmingCharacters(in: .whitespaces)
            guard remainder.isEmpty else {
                throw InjectionError.unsafeFrontmatter
            }
            let endIndex = try replacementEnd(in: lines, after: startIndex, before: closingIndex)
            lines.replaceSubrange(startIndex..<endIndex, with: provenanceLines)
        } else {
            try insert(provenanceLines, into: &lines, before: closingIndex)
        }
        return lines.joined(separator: newline)
    }
    private static func replacementEnd(in lines: [String], after start: Int, before closing: Int) throws -> Int {
        var end = start + 1
        while end < closing {
            let line = lines[end]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                throw InjectionError.unsafeFrontmatter
            }
            if line.first?.isWhitespace == true {
                end += 1
                continue
            }
            guard !isSequenceEntry(trimmed) else {
                throw InjectionError.unsafeFrontmatter
            }
            break
        }
        return end
    }
    private static func isSequenceEntry(_ line: String) -> Bool {
        line.first == "-" && (line.count == 1 || line.dropFirst().first?.isWhitespace == true)
    }
    private static func insert(_ provenance: [String], into lines: inout [String], before closingIndex: Int) throws {
        guard acceptsBlockMappingInsertion(lines[1..<closingIndex]) else {
            throw InjectionError.unsafeFrontmatter
        }
        lines.insert(contentsOf: provenance, at: closingIndex)
    }
    private static func acceptsBlockMappingInsertion(_ lines: ArraySlice<String>) -> Bool {
        var sawMappingEntry = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true {
                guard sawMappingEntry else { return false }
                continue
            }
            guard isPlainBlockMappingEntry(line) else { return false }
            sawMappingEntry = true
        }
        return true
    }
    private static func isPlainBlockMappingEntry(_ line: String) -> Bool {
        guard let separator = mappingSeparator(in: line) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy { character in
            character.isLetter || character.isNumber || character.isWhitespace || "_-.".contains(character)
        }
    }

    private static func isAgentProvenanceEntry(_ line: String) -> Bool {
        guard line.first?.isWhitespace != true,
              let separator = mappingSeparator(in: line) else { return false }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        return key == "agent_provenance" || key == "\"agent_provenance\"" || key == "'agent_provenance'"
    }

    private static func mappingSeparator(in line: String) -> String.Index? {
        line.indices.first(where: { index in
            guard line[index] == ":", index != line.startIndex, !isSequenceEntry(line) else { return false }
            let next = line.index(after: index)
            return next == line.endIndex || line[next].isWhitespace
        })
    }

    @discardableResult
    static func apply(
        to document: inout FrontmatterDocument,
        relativePath: String,
        timestampProvider: TimestampProvider,
        failureLogger: @Sendable (String) -> Void
    ) -> Bool {
        do {
            document.applyBifrostProvenance(writtenAt: try timestampProvider())
            return true
        } catch {
            let neutralizedStaleAttribution = neutralizeStructuredProvenance(in: &document)
            logFailure(
                error,
                relativePath: relativePath,
                neutralizedStaleAttribution: neutralizedStaleAttribution,
                failureLogger: failureLogger
            )
            return false
        }
    }

    private static func neutralizeStructuredProvenance(in document: inout FrontmatterDocument) -> Bool {
        guard let prior = document.frontmatter[YAMLProvenanceKey.activeName] else { return false }
        var neutralKey = YAMLProvenanceKey.neutralName
        var suffix = 2
        while document.frontmatter[neutralKey] != nil {
            neutralKey = "\(YAMLProvenanceKey.neutralName)_\(suffix)"
            suffix += 1
        }
        document.frontmatter = YAMLMap(document.frontmatter.pairs.map { key, value in
            let isActive = key == YAMLProvenanceKey.activeName
            return (isActive ? neutralKey : key, isActive ? prior : value)
        })
        return true
    }

    private static func logFailure(
        _ error: Error,
        relativePath: String,
        neutralizedStaleAttribution: Bool,
        failureLogger: @Sendable (String) -> Void
    ) {
        let outcome = neutralizedStaleAttribution
            ? "neutralized stale attribution before writing sanitized bytes"
            : "writing requested bytes without refreshed provenance"
        let message = "Bifrost provenance tagging failed for \(relativePath); "
            + "\(outcome): \(error.localizedDescription)"
        failureLogger(message)
    }
}
