import Foundation
import YggdrasilCore

enum VaultWriteProvenance {
    typealias TimestampProvider = @Sendable () throws -> String
    private static let activeProvenanceName = "agent_provenance"
    private static let neutralProvenanceName = "former_writer_attribution"

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
            let sanitization = YAMLProvenanceTransformer.sanitizingFallback(text)
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

        if let inserted = YAMLProvenanceTransformer.insertingProvenance(
            into: text,
            writtenAt: writtenAt
        ) {
            return inserted
        }

        let lines = text.components(separatedBy: newline)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw InjectionError.unsafeFrontmatter
        }
        return try refreshingExistingProvenance(
            in: text,
            lines: lines,
            closingIndex: closingIndex,
            writtenAt: writtenAt
        )
    }

    private static func refreshingExistingProvenance(
        in text: String,
        lines originalLines: [String],
        closingIndex: Int,
        writtenAt: String
    ) throws -> String {
        let newline = text.hasPrefix("---\r\n") ? "\r\n" : "\n"
        let provenanceLines = [
            "agent_provenance:",
            "  author: bifrost-ios",
            "  written_at: \(writtenAt)",
            "  origin: direct-fs"
        ]
        var lines = originalLines
        let frontmatter = lines[1..<closingIndex].joined(separator: newline)
        if YAMLProvenanceTransformer.requiresSemanticKeyFallback(in: frontmatter) {
            guard let upserted = YAMLProvenanceTransformer.upsertingProvenance(
                into: text,
                writtenAt: writtenAt
            ) else {
                throw InjectionError.unsafeFrontmatter
            }
            return upserted
        }

        let candidates = lines[1..<closingIndex].indices.filter {
            let line = lines[$0]
            return line.first?.isWhitespace != true && line.contains("agent_provenance")
        }
        guard candidates.count == 1,
              let startIndex = candidates.first,
              lines[startIndex].hasPrefix("agent_provenance:") else {
            throw InjectionError.unsafeFrontmatter
        }
        let remainder = lines[startIndex].dropFirst("agent_provenance:".count)
            .trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty else { throw InjectionError.unsafeFrontmatter }
        let endIndex = try replacementEnd(in: lines, after: startIndex, before: closingIndex)
        guard replacementPreservesAnchorReferences(
            in: lines,
            replacing: startIndex..<endIndex,
            before: closingIndex
        ) else {
            throw InjectionError.unsafeFrontmatter
        }
        lines.replaceSubrange(startIndex..<endIndex, with: provenanceLines)
        return lines.joined(separator: newline)
    }

    private static func replacementPreservesAnchorReferences(
        in lines: [String],
        replacing range: Range<Int>,
        before closing: Int
    ) -> Bool {
        let removed = lines[range].joined(separator: "\n")
        guard removed.contains("&") else { return true }
        let retained = (lines[1..<range.lowerBound] + lines[range.upperBound..<closing])
            .joined(separator: "\n")
        return !retained.contains("*")
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
        guard let prior = document.frontmatter[activeProvenanceName] else { return false }
        var neutralKey = neutralProvenanceName
        var suffix = 2
        while document.frontmatter[neutralKey] != nil {
            neutralKey = "\(neutralProvenanceName)_\(suffix)"
            suffix += 1
        }
        document.frontmatter = YAMLMap(document.frontmatter.pairs.map { key, value in
            let isActive = key == activeProvenanceName
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
