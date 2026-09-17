import SwiftUI
import UniformTypeIdentifiers

struct AssistantView: View {
    @EnvironmentObject private var assistant: AssistantCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var text = ""
    @State private var detent = PresentationDetent.medium
    @State private var auxiliary: AssistantAuxiliary?
    @State private var pickingUploads = false
    @State private var renameTarget: AssistantConversation?
    @State private var renamedTitle = ""
    @State private var renameError: String?
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if !assistant.consented { disclosure }
            else {
                transcript
                if let error = assistant.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text(error).font(.footnote).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if !assistant.connected { Button("Reconnect") { assistant.prepare() } }
                    }.foregroundStyle(Color(uiColor: .secondaryLabel)).padding(.horizontal).padding(.vertical, 8)
                }
                if assistant.conversation.canResume, assistant.approval == nil { resumeBar }
                if assistant.needsAttachmentRecovery {
                    Button("Continue Without Old Uploads") { assistant.continueWithoutExpiredUploads() }.buttonStyle(.bordered).padding(8)
                }
                if let call = assistant.approval { approvalCard(call) }
                AssistantVoicePanel(voice: assistant.voice, expand: { detent = .large })
                if let url = assistant.artifact {
                    ShareLink(item: url) { Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up").font(.subheadline) }.padding(8)
                }
                composer
            }
        }
        .background(Color(uiColor: .systemBackground))
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .onAppear { assistant.present() }
        .onDisappear { assistant.dismiss() }
        .onChange(of: typing) { _, value in if value { detent = .large } }
        .onChange(of: assistant.approval?.id) { _, value in if value != nil { detent = .large } }
        .sheet(item: $auxiliary) { item in
            switch item {
            case .history: historySheet
            case .settings: settingsSheet
            }
        }
        .fileImporter(isPresented: Binding(get: { pickingUploads || assistant.filePurpose != nil }, set: { if !$0 { pickingUploads = false } }), allowedContentTypes: assistant.filePurpose == "backup" ? [.zip, .json, .data] : [.image, .pdf, .plainText, .commaSeparatedText, .data], allowsMultipleSelection: assistant.filePurpose != "backup") { result in
            if assistant.filePurpose != nil { assistant.selectFilesResult(result) }
            else {
                do { assistant.attach(try result.get()) } catch { assistant.error = error.localizedDescription }
            }
            pickingUploads = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.sheet")
    }
    private var header: some View {
        HStack(spacing: 10) {
            AssistantBrandMark(size: 42)
            Text("Ask Finances")
                .font(.title3.weight(.regular))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Menu {
                Button("History", systemImage: "clock") { auxiliary = .history }
                Button("New Chat", systemImage: "square.and.pencil") { assistant.newConversation() }
                Button("Assistant Settings", systemImage: "slider.horizontal.3") { auxiliary = .settings }
            } label: { headerControl("ellipsis") }
                .accessibilityLabel("Assistant Options")
            Button { assistant.dismiss(); dismiss() } label: { headerControl("xmark") }
                .accessibilityLabel("Close")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }
    private func headerControl(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 38, height: 38)
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your finances, in conversation", systemImage: "sparkles").font(.title3.weight(.semibold))
            Text("Ask questions, find receipts, and make bookkeeping changes using your current iPhone data.")
            Text("OpenAI processes your messages, requested records, attachments, and audio during voice chat. Your ledger stays on this device and in iCloud. OpenAI’s API retention policy applies.").font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
            Text("Work pauses when you leave. Chat history stays on this device for 30 days. Voice starts only when you tap its button.").font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
            Link("OpenAI data policy", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
            Button("Continue") { assistant.acceptConsent() }.buttonStyle(.borderedProminent).accessibilityIdentifier("assistant.consent")
        }.padding(24).frame(maxHeight: .infinity, alignment: .top)
    }
    private var welcome: some View {
        VStack(spacing: 12) {
            Text("What do you need help with?").font(.title3.weight(.semibold))
            Text("Find transactions, check balances, review spending, add or edit entries, and attach receipts.")
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
    }
    private var transcript: some View {
        Group {
            if assistant.conversation.messages.isEmpty && assistant.conversation.activity.isEmpty && assistant.streamingText.isEmpty {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView {
                            welcome.frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .accessibilityIdentifier("assistant.welcome")
                    }
                    if assistant.isRunning || assistant.isConnecting { activityIndicator.padding(.horizontal, 22).padding(.bottom, 12) }
                }
            } else {
                messageTranscript
            }
        }
    }
    private var messageTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !assistant.conversation.activity.isEmpty {
                        DisclosureGroup("Actions · \(assistant.conversation.activity.count)") {
                            ForEach(assistant.conversation.activity) { action in actionRow(action) }
                        }
                        .disclosureGroupStyle(AssistantActionsStyle())
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                    }
                    ForEach(assistant.conversation.messages) { message in
                        messageBubble(message.text, isUser: message.role == "user", identifier: "assistant.message.\(message.role)")
                            .id(message.id)
                    }
                    if !assistant.streamingText.isEmpty {
                        messageBubble(assistant.streamingText, isUser: false, identifier: "assistant.streaming")
                    }
                    if assistant.isRunning || assistant.isConnecting {
                        activityIndicator.padding(.horizontal, 4).padding(.vertical, 4)
                    }
                    Color.clear.frame(height: 1).id(AssistantTranscriptAnchor.latest)
                }.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { proxy.scrollTo(AssistantTranscriptAnchor.latest, anchor: .bottom) }
            .onChange(of: assistant.conversation.messages.count) { withAnimation { proxy.scrollTo(AssistantTranscriptAnchor.latest, anchor: .bottom) } }
        }
    }
    private var activityIndicator: some View {
        HStack(spacing: 10) {
            AssistantBrandMark(size: 26)
            Text(assistant.isConnecting ? "Connecting…" : assistant.activity)
                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
            ProgressView().controlSize(.mini).tint(.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
    private func messageBubble(_ source: String, isUser: Bool, identifier: String) -> some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 40) }
            AssistantMarkdown(source: source).equatable()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(identifier)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(isUser ? Color.accentColor.opacity(0.10) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if !isUser { Spacer(minLength: 16) }
        }
    }
    private func actionRow(_ call: AssistantToolCall) -> some View {
        let output = call.result.flatMap { try? JSONDecoder().decode(AssistantJSON.self, from: Data($0.utf8)) }
        return VStack(alignment: .leading, spacing: 3) {
            Label(call.label, systemImage: output?["ok"].bool == true ? "checkmark.circle" : "exclamationmark.circle")
            if let output, output["ok"].bool == false { Text(output["error"]["message"].string ?? "Action did not finish.") }
            if let output, output["result"]["status"].string == "saved_locally" { Text("Saved on this iPhone · iCloud delivery is separate") }
            if let raw = output?["result"]["id"].string, let id = UUID(uuidString: raw), assistant.store.transaction(id) != nil {
                Button { assistant.navigationRequest = .object(["view": .string("register"), "transaction": .string(id.uuidString)]) } label: {
                    Text("View Transaction").frame(minHeight: 44).contentShape(Rectangle())
                }
            }
        }.padding(.vertical, 2)
    }
    private var resumeBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Conversation paused").font(.subheadline.weight(.semibold))
                Text("Completed actions remain saved.").font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer()
            Button("Resume") { assistant.resume() }.buttonStyle(.borderedProminent).accessibilityIdentifier("assistant.resume")
            Menu { Button("Cancel Remaining", role: .destructive) { assistant.cancelRemaining() } } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
        }.padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 18).padding(.bottom, 8)
    }
    private func approvalCard(_ call: AssistantToolCall) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Review: " + call.label, systemImage: "hand.raised").font(.headline)
            ScrollView { Text(assistant.approvalText).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 210)
            HStack { Button("Cancel", role: .cancel) { assistant.approve(false) }.buttonStyle(.bordered); Spacer(); Button("Confirm") { assistant.approve(true) }.buttonStyle(.borderedProminent).tint(.red) }
        }.padding(16).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 18).padding(.bottom, 8).accessibilityIdentifier("assistant.approval")
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if !assistant.uploadedFiles.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(Array(assistant.uploadedFiles.enumerated()), id: \.offset) { index, file in
                    Button { assistant.uploadedFiles.remove(at: index) } label: { Label(file["filename"].string ?? "Attachment", systemImage: "xmark.circle.fill").font(.caption).padding(7).background(.quaternary, in: Capsule()) }
                } } }.padding(.horizontal, 10)
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 4) {
                        composerInput.padding(.horizontal, 12)
                        HStack(spacing: 4) { attachmentButton; Spacer(); voiceButton; submitButton }
                    }
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        attachmentButton
                        composerInput
                        voiceButton
                        submitButton
                    }
                }
            }
            .padding(6)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
    private var composerInput: some View {
        TextField("Ask about your finances…", text: $text, axis: .vertical)
            .font(.body)
            .lineLimit(1...5)
            .focused($typing)
            .padding(.vertical, 11)
            .accessibilityIdentifier("assistant.composer")
    }
    private var attachmentButton: some View {
        Button { pickingUploads = true } label: {
            Image(systemName: "plus").font(.system(size: 21, weight: .regular)).frame(width: 44, height: 44).contentShape(Circle())
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Attach Files")
        .disabled(!assistant.connected || assistant.isRunning)
    }
    private var voiceButton: some View {
        Button { typing = false; detent = .large; assistant.startVoice() } label: {
            Image(systemName: "mic").font(.system(size: 20)).frame(width: 44, height: 44).contentShape(Circle())
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
        .accessibilityLabel("Start Voice Chat")
        .disabled(!assistant.connected || assistant.isConnecting || assistant.isRunning || assistant.conversation.canResume)
    }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && assistant.connected && !assistant.isConnecting && !assistant.isRunning && !assistant.conversation.canResume
    }
    @ViewBuilder private var submitButton: some View {
        if assistant.isRunning {
            Button { assistant.pause() } label: {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("Stop")
            .accessibilityIdentifier("assistant.stop")
        } else {
            Button { if assistant.send(text) { text = "" } } label: {
                Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 44, height: 44)
                    .background(canSend ? Color.accentColor : Color(uiColor: .quaternarySystemFill), in: Circle())
            }
            .accessibilityLabel("Send Message")
            .accessibilityIdentifier("assistant.send")
            .disabled(!canSend)
        }
    }
    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(assistant.history) { conversation in
                    Button { assistant.selectConversation(conversation); auxiliary = nil } label: {
                        VStack(alignment: .leading) { Text(conversation.title).foregroundStyle(Color.primary); Text(conversation.updated, style: .date).font(.caption).foregroundStyle(Color.secondary) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("assistant.history.\(conversation.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { assistant.deleteConversation(conversation.id) }
                        Button("Rename", systemImage: "pencil") {
                            renameError = nil; renamedTitle = conversation.title; renameTarget = conversation
                        }.tint(.blue)
                    }
                }
                if let renameError { Text(renameError).font(.footnote).foregroundStyle(.red) }
            }.overlay { if assistant.history.isEmpty { ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right", description: Text("Conversations stay on this device for 30 days.")) } }
            .navigationTitle("History").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { auxiliary = nil } } }
            .alert("Rename Conversation", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } }), presenting: renameTarget) { conversation in
                TextField("Conversation name", text: $renamedTitle)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("assistant.rename.title")
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Save") {
                    do { try assistant.renameConversation(conversation.id, title: renamedTitle) }
                    catch { renameError = error.localizedDescription }
                    renameTarget = nil
                }
                .disabled(renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renamedTitle.trimmingCharacters(in: .whitespacesAndNewlines).count > 80)
            } message: { _ in Text("Choose a name up to 80 characters.") }
            .onChange(of: assistant.identity) { _, _ in renameTarget = nil; renameError = nil }
        }
    }
    private var settingsSheet: some View {
        NavigationStack {
            AssistantPreferencesView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { auxiliary = nil } } }
        }
    }
}

struct AssistantPreferencesView: View {
    @EnvironmentObject private var preferences: AssistantPreferencesStore
    @State private var draft = AssistantSettings()
    @State private var baseline = AssistantPreferences()
    @State private var saveError: String?

    var body: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: Binding(get: { draft.model }, set: { model in
                    var next = draft; next.model = model
                    let efforts = AssistantSettings.models.first { $0.id == model }?.efforts ?? []
                    if !efforts.contains(next.effort) { next.effort = efforts.contains("medium") ? "medium" : efforts.first ?? "low" }
                    save(next)
                })) {
                    ForEach(AssistantSettings.models) { Text($0.label).tag($0.id) }
                }
                Picker("Reasoning", selection: Binding(get: { draft.effort }, set: { var next = draft; next.effort = $0; save(next) })) {
                    ForEach(AssistantSettings.models.first { $0.id == draft.model }?.efforts ?? [draft.effort], id: \.self) { Text($0.capitalized).tag($0) }
                }
            }.disabled(!preferences.ready || !preferences.conflicts.isEmpty)
            Section {
                TextEditor(text: Binding(get: { draft.customInstructions }, set: { var next = draft; next.customInstructions = $0; save(next) }))
                    .frame(minHeight: 120)
                    .accessibilityLabel("Custom Instructions")
                    .disabled(!preferences.ready || !preferences.conflicts.isEmpty)
            } header: { Text("Instructions") } footer: {
                Text("Applies to new requests in every conversation. Paused work keeps the settings it started with.")
            }
            if let saveError { Section { Text(saveError).foregroundStyle(.red) } }
            if !preferences.conflicts.isEmpty {
                let local = preferences.value, remote = preferences.remote
                Section("Settings Changed on Both Devices") {
                    Text(preferences.conflicts.joined(separator: ", "))
                    LabeledContent("This iPhone", value: "\(local.model) · \(local.effort)")
                    Text(local.instructions.isEmpty ? "No custom instructions" : local.instructions).font(.footnote)
                    LabeledContent("iCloud", value: "\(remote.model) · \(remote.effort)")
                    Text(remote.instructions.isEmpty ? "No custom instructions" : remote.instructions).font(.footnote)
                    Button("Keep This iPhone") { resolve(true, local: local, remote: remote) }
                    Button("Use iCloud") { resolve(false, local: local, remote: remote) }
                }
            }
            Section("Storage") {
                Text(preferences.isLocalOnly ? "Saved on this iPhone · Sample mode" : preferences.pending ? "Saved on this iPhone · Pending iCloud sync" : preferences.ready ? "Synced with iCloud" : "Connecting to iCloud…")
                if !preferences.error.isEmpty { Text(preferences.error).font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel)) }
                if preferences.busy { ProgressView() }
                if !preferences.isLocalOnly {
                    Button("Sync Settings") { Task { await preferences.refresh() } }.disabled(preferences.busy)
                    Text("These app settings restore after reinstalling with the same iCloud account once synced. Conversation history stays on this device.").font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
        }
        .navigationTitle("Ask AI Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await preferences.refresh(); load() }
        .onChange(of: preferences.value) { load() }
        .onChange(of: preferences.scope) { saveError = nil; load() }
    }
    private func load() { baseline = preferences.value; draft = preferences.settings }
    private func save(_ next: AssistantSettings) {
        do { try preferences.edit(next, expected: baseline); saveError = nil; load() }
        catch { saveError = error.localizedDescription }
    }
    private func resolve(_ localChoice: Bool, local: AssistantPreferences, remote: AssistantPreferences) {
        do { try preferences.resolve(keepLocal: localChoice, expectedLocal: local, expectedRemote: remote); saveError = nil; load() }
        catch { saveError = error.localizedDescription }
    }
}

private enum AssistantAuxiliary: String, Identifiable { case history, settings; var id: String { rawValue } }
private enum AssistantTranscriptAnchor: Hashable { case latest }

private struct AssistantBrandMark: View {
    var size: CGFloat
    var body: some View {
        Image("AssistantLogo")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct AssistantActionsStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    configuration.label
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("assistant.actions")
            if configuration.isExpanded {
                configuration.content
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

private struct AssistantVoicePanel: View {
    @ObservedObject var voice: AssistantVoiceSession
    var expand: () -> Void
    var body: some View {
        if voice.active || voice.connecting {
            VStack(spacing: 12) {
                Image(systemName: voice.muted ? "mic.slash.fill" : "waveform").font(.system(size: 34)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                Text(voice.status).font(.headline)
                HStack(spacing: 20) {
                    Button(voice.muted ? "Unmute" : "Mute", systemImage: voice.muted ? "mic.slash" : "mic") { voice.mute() }
                    Button("Type Instead", systemImage: "keyboard") { voice.stop() }
                    Button("End Voice", systemImage: "phone.down.fill", role: .destructive) { voice.stop() }
                }.font(.subheadline).buttonStyle(.bordered)
            }.padding(16).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.05)).onAppear(perform: expand)
        }
    }
}
