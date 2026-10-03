import SwiftUI

struct CloudSyncConflictReview: View {
    let conflicts: [CloudKitSyncConflict]
    let data: JournalData
    let onApply: ([CloudKitConflictResolution]) async throws -> Void
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var choices: [String: Int] = [:]
    @State private var reviewed: [String: CloudKitSyncConflict] = [:]
    @State private var showAllFields = false
    @State private var busy = false
    @State private var message = ""
    @State private var error = ""

    private var chosenCount: Int { conflicts.filter { (choices[$0.id] ?? 0) != 0 }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Review Conflicts").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }.disabled(busy)
            }.padding()
            Text("\(conflicts.count) items need review. Choose versions below, then apply your choices together.")
                .foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 12)
            bulkControls.padding(.horizontal).padding(.bottom, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(conflicts) { conflict in
                        CloudSyncConflictCard(conflict: conflict,
                            context: CloudKitConflictComparison.context(conflict.local.operation == "delete" ? conflict.remote : conflict.local, data: data), fields: CloudKitConflictComparison.fields(conflict, data: data),
                            selected: Binding(get: { selected.contains(conflict.id) }, set: { value in
                                if value { selected.insert(conflict.id) } else { selected.remove(conflict.id) }
                            }), choice: Binding(get: { choices[conflict.id] ?? 0 }, set: { value in
                                choices[conflict.id] = value; reviewed[conflict.id] = conflict
                            }), showAllFields: showAllFields)
                    }
                    if conflicts.isEmpty { Text("No conflicts remain.").font(.headline).padding(.vertical) }
                }.padding()
            }.disabled(busy)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled).accessibilityLabel("Error: " + error) }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
                #if os(macOS)
                HStack {
                    Text(busy ? "Checking and applying selected versions…" : "\(chosenCount) choices ready · \(conflicts.count - chosenCount) undecided")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(busy ? "Applying…" : "Apply \(chosenCount) \(chosenCount == 1 ? "Choice" : "Choices") & Sync") { apply() }
                        .buttonStyle(.borderedProminent).disabled(busy || chosenCount == 0)
                }
                #else
                Text(busy ? "Checking and applying selected versions…" : "\(chosenCount) choices ready · \(conflicts.count - chosenCount) undecided")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(busy ? "Applying…" : "Apply \(chosenCount) \(chosenCount == 1 ? "Choice" : "Choices") & Sync") { apply() }
                    .buttonStyle(.borderedProminent).disabled(busy || chosenCount == 0)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                #endif
            }.padding()
        }
        .onAppear { onRefresh() }
        .onChange(of: conflicts) { _, updated in
            let ids = Set(updated.map(\.id))
            selected.formIntersection(ids)
            var changed = false
            for (id, snapshot) in reviewed {
                if !updated.contains(snapshot), ids.contains(id) { choices[id] = nil; reviewed[id] = nil; changed = true }
            }
            choices = choices.filter { ids.contains($0.key) }; reviewed = reviewed.filter { ids.contains($0.key) }
            if changed { message = "An item changed. Review it again; your other choices are retained." }
        }
        .interactiveDismissDisabled(busy)
    }

    private var bulkControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(selected.count == conflicts.count && !conflicts.isEmpty ? "Deselect All" : "Select All") {
                    selected = selected.count == conflicts.count ? [] : Set(conflicts.map(\.id))
                }
                Text("\(selected.count) selected").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show all fields", isOn: $showAllFields).toggleStyle(.checkboxCompat)
            }
            HStack {
                Menu("Choose for Selected") {
                    Button("Keep This Device") { choose(1, ids: selected) }
                    Button("Use iCloud") { choose(2, ids: selected) }
                    Button("Clear Choices") { choose(0, ids: selected) }
                }.disabled(selected.isEmpty)
                Menu("Choose for All") {
                    Button("Keep This Device for All") { choose(1, ids: Set(conflicts.map(\.id))) }
                    Button("Use iCloud for All") { choose(2, ids: Set(conflicts.map(\.id))) }
                    Button("Clear All Choices") { choices = [:]; reviewed = [:] }
                }.disabled(conflicts.isEmpty)
            }
        }.disabled(busy)
    }

    private func choose(_ value: Int, ids: Set<String>) {
        for conflict in conflicts where ids.contains(conflict.id) {
            choices[conflict.id] = value; reviewed[conflict.id] = conflict
        }
    }

    private func apply() {
        let batch = conflicts.compactMap { conflict -> CloudKitConflictResolution? in
            guard let choice = choices[conflict.id], choice != 0, let snapshot = reviewed[conflict.id] else { return nil }
            return .init(conflict: snapshot, keepLocal: choice == 1)
        }
        busy = true; error = ""; message = ""
        Task { @MainActor in
            defer { busy = false; onRefresh() }
            do {
                try await onApply(batch)
                for choice in batch { choices[choice.conflict.id] = nil; reviewed[choice.conflict.id] = nil }
                message = "\(batch.count) choices applied and saved. Any remaining items can be reviewed later."
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CloudSyncConflictCard: View {
    let conflict: CloudKitSyncConflict
    let context: String
    let fields: [CloudKitConflictField]
    @Binding var selected: Bool
    @Binding var choice: Int
    let showAllFields: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $selected) {
                Text(CloudKitConflictComparison.title(conflict.local.operation == "delete" ? conflict.remote : conflict.local)).font(.headline)
            }.toggleStyle(.checkboxCompat)
            if !context.isEmpty { Text(context).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
            Text("\(fields.filter(\.changed).count) fields differ").font(.footnote).foregroundStyle(.secondary)
            Picker("Version to keep", selection: $choice) {
                Text("Decide Later").tag(0)
                Text("Keep This Device").tag(1)
                Text("Use iCloud").tag(2)
            }.pickerStyle(.menu)
            if !fields.contains(where: \.changed) {
                Text("The stored fields match. A sync version still needs a choice; no field changes will be hidden.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(fields.filter { showAllFields || $0.changed }) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.label).font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    HStack(alignment: .top, spacing: 16) {
                        value(field.local, label: "This Device", changed: field.changed)
                        value(field.remote, label: "iCloud", changed: field.changed)
                    }
                    #else
                    value(field.local, label: "This Device", changed: field.changed)
                    value(field.remote, label: "iCloud", changed: field.changed)
                    #endif
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(field.changed ? Color.orange.opacity(0.09) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.background).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
    }

    private func value(_ text: String, label: String, changed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(text).fontWeight(changed ? .semibold : .regular).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ConflictCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        Toggle(configuration).toggleStyle(.checkbox)
        #else
        Button { configuration.isOn.toggle() } label: {
            HStack {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label
            }
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Selected" : "Not selected")
        #endif
    }
}
private extension ToggleStyle where Self == ConflictCheckboxStyle {
    static var checkboxCompat: ConflictCheckboxStyle { ConflictCheckboxStyle() }
}
