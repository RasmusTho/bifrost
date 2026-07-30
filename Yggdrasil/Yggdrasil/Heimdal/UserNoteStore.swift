import Foundation

/// One user-authored note block.
///
/// `noteBlockID` is minted once, on first write, and never re-minted; `revision`
/// increments per edit. Together they are the idempotency key the CDLM-07
/// endpoint keys on, so a resend after a lost response updates rather than
/// duplicates.
struct UserNoteBlock: Codable, Equatable, Identifiable {
    let noteBlockID: String
    var revision: Int
    var text: String
    let createdAt: Date
    var updatedAt: Date
    /// The highest revision the hub has acknowledged. `nil` means nothing about
    /// this block has been acknowledged yet.
    var ackedRevision: Int?

    var id: String { noteBlockID }

    /// Unsynced while the acknowledged revision lags the local one. An ack for
    /// revision 1 does not make revision 2 synced — that would claim durability
    /// the hub never granted for the newer text.
    var isSynced: Bool { ackedRevision == revision }

    enum CodingKeys: String, CodingKey {
        case noteBlockID = "note_block_id"
        case revision
        case text
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case ackedRevision = "acked_revision"
    }
}

/// Durable client store for user notes.
///
/// The retain-until-acknowledged discipline CDLM-03 applies to media originals,
/// applied to text: a note is on disk from the moment it is written, and stays
/// unsynced until the hub's ack for *that revision* persists. Nothing is ever
/// dropped because a send failed, and no note is ever marked synced on the
/// strength of an in-memory success flag.
struct UserNoteStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.fileURL = directoryURL.appendingPathComponent("user-notes.json")
        self.fileManager = fileManager
    }

    func load() -> [UserNoteBlock] {
        guard let data = try? Data(contentsOf: fileURL),
              let blocks = try? Self.decoder.decode([UserNoteBlock].self, from: data) else { return [] }
        return blocks.sorted { $0.createdAt < $1.createdAt }
    }

    /// Writes a new note block, minting its identity once.
    @discardableResult
    func append(text: String, at date: Date = Date()) throws -> UserNoteBlock {
        var blocks = load()
        let block = UserNoteBlock(
            noteBlockID: UUID().uuidString.lowercased(),
            revision: 1,
            text: text,
            createdAt: date,
            updatedAt: date,
            ackedRevision: nil
        )
        blocks.append(block)
        try persist(blocks)
        return block
    }

    /// Edits an existing block, bumping its revision. The identity is stable, so
    /// the hub sees an update to a block it already knows rather than a new one.
    @discardableResult
    func edit(noteBlockID: String, text: String, at date: Date = Date()) throws -> UserNoteBlock? {
        var blocks = load()
        guard let index = blocks.firstIndex(where: { $0.noteBlockID == noteBlockID }) else { return nil }
        blocks[index].revision += 1
        blocks[index].text = text
        blocks[index].updatedAt = date
        try persist(blocks)
        return blocks[index]
    }

    /// Blocks whose current revision the hub has not acknowledged.
    func unsynced() -> [UserNoteBlock] {
        load().filter { !$0.isSynced }
    }

    /// Records an ack. Deliberately ignores an ack for a revision older than the
    /// local one: the user has edited since, and marking that synced would claim
    /// the hub holds text it has never seen.
    func recordAck(_ ack: UserNoteAck) throws {
        var blocks = load()
        guard let index = blocks.firstIndex(where: { $0.noteBlockID == ack.noteBlockID }) else { return }
        guard ack.revision >= (blocks[index].ackedRevision ?? 0) else { return }
        guard ack.revision <= blocks[index].revision else { return }
        blocks[index].ackedRevision = ack.revision
        try persist(blocks)
    }

    private func persist(_ blocks: [UserNoteBlock]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(blocks)
        let temporaryURL = fileURL.appendingPathExtension("writing")
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
