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

        if let upserted = YAMLProvenanceTransformer.upsertingProvenance(
            into: text,
            writtenAt: writtenAt
        ) {
            return upserted
        }
        throw InjectionError.unsafeFrontmatter
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
