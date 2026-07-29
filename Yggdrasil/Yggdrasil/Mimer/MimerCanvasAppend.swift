import Combine
import CoreTransferable
import Foundation
import UIKit
import UniformTypeIdentifiers

/// One ephemeral drag payload representation: its persisted representation is
/// still the markdown link rendered by `promotionBlock`, never app-local state.
struct MimerCanvasPromotion: Hashable, Sendable, Transferable {
    let relativePath: String
    let snippet: String

    private var markdownLink: String {
        let pathWithoutExtension = relativePath.hasSuffix(".md")
            ? String(relativePath.dropLast(3))
            : relativePath
        return "[[\(pathWithoutExtension)]]"
    }

    var plainTextRepresentation: String {
        "\(markdownLink)\n\(snippet)"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { promotion in
            Data(promotion.plainTextRepresentation.utf8)
        }
        DataRepresentation(importedContentType: .plainText) { data in
            guard let payload = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let lines = payload.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let markdownLink = lines.first,
                  markdownLink.hasPrefix("[["),
                  markdownLink.hasSuffix("]]"),
                  markdownLink.count > 4 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return MimerCanvasPromotion(
                relativePath: String(markdownLink.dropFirst(2).dropLast(2)),
                snippet: lines.count == 2 ? String(lines[1]) : ""
            )
        }
    }
}

/// The sole canvas write shape. It deliberately delegates to the existing
/// coordinated store seam; it owns only suffix construction, not conflict or
/// retry policy.
enum MimerCanvasAppend {
    static func annotationBlock(_ text: String) -> String {
        let quotedText = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")
        return "> [!note] Annotation\n\(quotedText)\n> — bifrost-ios"
    }

    static func promotionBlock(_ promotion: MimerCanvasPromotion) -> String {
        let snippet = promotion.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        let pathWithoutExtension = promotion.relativePath.hasSuffix(".md")
            ? String(promotion.relativePath.dropLast(3))
            : promotion.relativePath
        return "[[\(pathWithoutExtension)]]\(snippet.isEmpty ? "" : " — \(snippet)")"
    }

    static func appendBlock(
        to relativePath: String,
        block: String,
        using fileStore: VaultFileStore
    ) async throws {
        let normalizedBlock = block.trimmingCharacters(in: .newlines)
        guard !normalizedBlock.isEmpty else { return }

        try await fileStore.readModifyWrite(relativePath) { document in
            let separator: String
            if document.body.isEmpty || document.body.hasSuffix("\n\n") {
                separator = ""
            } else if document.body.hasSuffix("\n") {
                separator = "\n"
            } else {
                separator = "\n\n"
            }
            document.body += "\(separator)\(normalizedBlock)\n"
        }
    }
}

/// In-memory composition and visible failure state for one human-directed
/// append. It is intentionally not a queue: leaving the canvas loses it.
@MainActor
final class MimerCanvasAppendDraft: ObservableObject {
    @Published var annotationText = ""
    @Published private(set) var failureMessage: String?
    @Published private(set) var failureText = ""

    private let fileStore: VaultFileStore
    private var failedPath: String?
    private var failedBlock: String?
    private var failedClearsAnnotationDraft = false

    init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
    }

    /// Only an annotation submission may clear `annotationText`: a promotion
    /// drop appends an unrelated block and must never wipe an unrelated,
    /// unsaved annotation still sitting in the open composer.
    func submitAnnotation(to relativePath: String) async -> Bool {
        let text = annotationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failureMessage = "Enter an annotation before saving."
            failureText = annotationText
            return false
        }
        return await submit(
            block: MimerCanvasAppend.annotationBlock(text),
            visibleText: annotationText,
            to: relativePath,
            clearsAnnotationDraft: true
        )
    }

    func submitPromotion(_ promotion: MimerCanvasPromotion, to relativePath: String) async -> Bool {
        await submit(
            block: MimerCanvasAppend.promotionBlock(promotion),
            visibleText: promotion.snippet.isEmpty ? promotion.relativePath : promotion.snippet,
            to: relativePath,
            clearsAnnotationDraft: false
        )
    }

    func retry() async -> Bool {
        guard let failedPath, let failedBlock else { return false }
        return await submit(
            block: failedBlock,
            visibleText: failureText,
            to: failedPath,
            clearsAnnotationDraft: failedClearsAnnotationDraft
        )
    }

    func copyFailureText() {
        UIPasteboard.general.string = failureText
    }

    private func submit(
        block: String,
        visibleText: String,
        to relativePath: String,
        clearsAnnotationDraft: Bool
    ) async -> Bool {
        do {
            try await MimerCanvasAppend.appendBlock(to: relativePath, block: block, using: fileStore)
            if clearsAnnotationDraft {
                annotationText = ""
            }
            failureMessage = nil
            failureText = ""
            failedPath = nil
            failedBlock = nil
            failedClearsAnnotationDraft = false
            return true
        } catch {
            failureMessage = "Couldn't save. Your text is still here: \(error.localizedDescription)"
            failureText = visibleText
            failedPath = relativePath
            failedBlock = block
            failedClearsAnnotationDraft = clearsAnnotationDraft
            return false
        }
    }
}

/// The detail column's non-visual state: which note an in-progress
/// annotation is composed against, and whether a post-append refresh is
/// still targeting the current selection. Kept as a plain, testable type so
/// the selection-lifecycle rules (INV-B2-3, no clobbering a newer selection)
/// are exercised directly rather than only through SwiftUI view state.
@MainActor
final class MimerCanvasDetailCoordinator: ObservableObject {
    @Published private(set) var composedAnnotationPath: String?
    private var selectionToken = UUID()
    private let fileStore: VaultFileStore

    init(fileStore: VaultFileStore) {
        self.fileStore = fileStore
    }

    /// Called whenever the bound selection changes (including to a
    /// different note or to none), so an in-flight refresh for the prior
    /// note can detect it is now stale. Mirrors
    /// `MimerVaultColumnView.select`'s `noteSelectionID` guard.
    func selectionChanged() {
        selectionToken = UUID()
    }

    /// Begins composing an annotation against `path`. If a composition is
    /// already pending against a different note, its original target is
    /// kept: a draft the human can still see must never be silently
    /// retargeted or dropped (INV-B2-3).
    func beginAnnotationComposition(for path: String) {
        guard composedAnnotationPath == nil else { return }
        composedAnnotationPath = path
    }

    func annotationCompositionCommitted() {
        composedAnnotationPath = nil
    }

    /// Re-reads `path` after a successful append and, only if the selection
    /// has not moved on in the interim, hands the refreshed note to
    /// `applyRefreshedNote`. `currentSelectedPath` is evaluated after the
    /// read completes, so it reflects whatever is selected at that time, not
    /// at the moment the refresh was kicked off.
    func refresh(
        path: String,
        currentSelectedPath: @escaping () -> String?,
        applyRefreshedNote: (MimerCanvasNote) -> Void
    ) async {
        let token = selectionToken
        do {
            async let text = fileStore.read(path)
            async let modificationDate = fileStore.modificationDate(of: path)
            let refreshed = try await MimerCanvasNote(
                relativePath: path,
                text: text,
                modificationDate: modificationDate
            )
            guard token == selectionToken, currentSelectedPath() == path else { return }
            applyRefreshedNote(refreshed)
        } catch {
            // The append draft already preserves the human's unsaved text
            // only on a failed append. A post-write refresh failure does not
            // create another write path; reopening the note performs the
            // normal read.
        }
    }
}
