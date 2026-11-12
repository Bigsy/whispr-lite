import SwiftUI
import WhisprLiteCore

struct DictionaryListEditor: View {
    @Binding var dictionary: DictionaryEntries
    @State private var draft = ""
    @State private var editing: String?
    @State private var message = ""
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Dictionary and phrases").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(dictionary.entries.count) entries · A–Z").font(.caption).foregroundStyle(.secondary)
            }
            Text("Names and terms guide the local model. For an exact correction, add spoken phrase > Written phrase; case is ignored. You can paste comma-separated words to add several.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Word, phrase, or spoken > Written", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(editing == nil ? "New dictionary entry" : "Edit dictionary entry")
                    .focused($entryFocused)
                    .onSubmit(apply)
                    .onChange(of: draft) { _, _ in message = "" }
                Button(editing == nil ? "Add" : "Update", action: apply)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editing != nil {
                    Button("Cancel", action: cancel)
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if dictionary.entries.isEmpty {
                            Text("No entries yet. Add a name or phrase above.")
                                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                        }
                        ForEach(dictionary.entries, id: \.self) { entry in
                            entryRow(entry).id(entry)
                            if entry != dictionary.entries.last { Divider() }
                        }
                    }
                }
                .frame(height: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .onChange(of: dictionary) { old, new in
                    if let added = new.entries.first(where: { !old.entries.contains($0) }) {
                        proxy.scrollTo(added, anchor: .center)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(entry).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editing = entry; draft = entry; message = ""; entryFocused = true
            } label: { Image(systemName: "pencil") }
                .help("Edit entry").accessibilityLabel("Edit \(entry)")
            Button(role: .destructive) {
                dictionary.remove(entry)
                if editing == entry { cancel() }
            } label: { Image(systemName: "minus.circle") }
                .help("Remove entry").accessibilityLabel("Remove \(entry)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(editing == entry ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private func apply() {
        if let error = DictionaryEntries.validationMessage(for: draft) {
            message = error
            return
        }
        let previous = dictionary
        if let editing { dictionary.replace(editing, with: draft) }
        else { dictionary.add(draft) }
        if editing == nil, dictionary == previous {
            message = "That entry is already in the dictionary."
            return
        }
        draft = ""; editing = nil; message = ""; entryFocused = true
    }

    private func cancel() {
        draft = ""; editing = nil; message = ""
    }
}
