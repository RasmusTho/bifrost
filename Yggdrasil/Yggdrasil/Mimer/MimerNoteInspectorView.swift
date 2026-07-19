import Foundation
import SwiftUI
import YggdrasilCore

struct NoteInspectorModel {
    let uuid: String?
    let zone: String?
    let origin: String?
    let agentProvenance: [String: String]
    let modifiedDescription: String?

    init(text: String, modificationDate: Date?) {
        let document = try? FrontmatterDocument.parse(text)
        uuid = document?.frontmatter["uuid"]?.stringValue
        zone = document?.frontmatter["zone"]?.stringValue
        origin = document?.frontmatter["origin"]?.stringValue
        agentProvenance = document?.frontmatter["agent_provenance"]?.mapValue?.pairs.reduce(into: [:]) {
            let renderedValue = YAMLCodec.serialize($1.1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            $0[$1.0] = $1.1.stringValue ?? renderedValue
        } ?? [:]
        modifiedDescription = modificationDate.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        }
    }

    var uuidDescription: String { uuid ?? "No uuid present" }
}

struct MimerNoteInspectorView: View {
    let model: NoteInspectorModel

    var body: some View {
        List {
            Section("Note metadata") {
                LabeledContent("uuid", value: model.uuidDescription)
                if let zone = model.zone { LabeledContent("zone", value: zone) }
                if let origin = model.origin { LabeledContent("origin", value: origin) }
                if let modified = model.modifiedDescription { LabeledContent("modified", value: modified) }
            }
            if !model.agentProvenance.isEmpty {
                Section("agent_provenance") {
                    ForEach(model.agentProvenance.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: model.agentProvenance[key] ?? "")
                    }
                }
            }
        }
        .navigationTitle("Inspector")
    }
}
