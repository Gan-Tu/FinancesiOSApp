import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var route: EditorRoute?
    @State private var confirmingJournalDelete: Ledger?
    @State private var confirmingCurrencyDelete: Commodity?
    @State private var editorRoute: EditorRoute?
    @AppStorage(JournalVisibility.preferenceKey, store: MobileDisplayPreferences.defaults) private var hiddenJournalIDs = ""
    private var visibility: JournalVisibility { JournalVisibility(rawValue: hiddenJournalIDs) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CloudSyncManagementView()
                    } label: {
                        SettingsIconLabel(title: "iCloud Sync", systemImage: "icloud.fill", tint: .blue)
                    }
                    NavigationLink {
                        SecuritySettingsView()
                    } label: {
                        SettingsIconLabel(title: "Security", systemImage: "lock.fill", tint: .red)
                    }
                }

                Section {
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        SettingsIconLabel(title: "Backup", systemImage: "externaldrive.fill", tint: .green)
                    }
                }

                Section {
                    NavigationLink {
                        FinancesForMacView()
                    } label: {
                        SettingsIconLabel(title: "Finances for Mac", systemImage: "macbook", tint: .green)
                    }
                    NavigationLink {
                        HelpSettingsView()
                    } label: {
                        SettingsIconLabel(title: "Help", systemImage: "questionmark.square.fill", tint: .purple)
                    }
                }

                Section {
                    NavigationLink {
                        DisplaySettingsView()
                    } label: {
                        SettingsIconLabel(title: "Display", systemImage: "textformat.size", tint: .green)
                    }
                }

                Section {
                    ForEach(visibility.visible(in: store.orderedLedgers)) { ledger in
                        HStack {
                            Button {
                                store.selectLedger(ledger.id)
                            } label: {
                                Label(ledger.name, systemImage: ledger.id == store.selectedLedgerID ? "checkmark.circle.fill" : "folder")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Menu {
                                Button {
                                    editorRoute = .journalRename(ledger)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    confirmingJournalDelete = ledger
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Actions for journal \(ledger.name)")
                        }
                    }
                    NavigationLink {
                        HiddenJournalsView()
                    } label: {
                        Label("Hidden Journals", systemImage: "archivebox")
                    }
                    Button {
                        editorRoute = .journalNew
                    } label: {
                        Label("New Journal", systemImage: "plus")
                    }
                } header: {
                    Text("Journals")
                }

                Section {
                    ForEach(store.selectedLedgerCurrencies) { currency in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(currency.symbol)
                                    .font(.body.weight(.semibold))
                                Text(currency.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button {
                                    editorRoute = .currency(store.draft(for: currency))
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    confirmingCurrencyDelete = currency
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Actions for currency \(currency.symbol)")
                        }
                    }
                    Button {
                        editorRoute = .currency(store.draft(for: nil))
                    } label: {
                        Label("New Currency", systemImage: "plus")
                    }
                } header: {
                    Text("Currencies")
                }

                Section {
                    ForEach(store.selectedLedgerTransactionTemplates) { template in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(template.name)
                                    .font(.body.weight(.medium))
                                Text(template.payee.isEmpty ? template.note : template.payee)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Menu {
                                Button {
                                    editorRoute = .template(store.templateDraft(for: template))
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Actions for template \(template.name)")
                        }
                    }
                    Button {
                        editorRoute = .template(store.templateDraft(for: nil))
                    } label: {
                        Label("New Template", systemImage: "plus")
                    }
                } header: {
                    Text("Templates")
                }
            }
            .navigationTitle("Settings")
            .listStyle(.insetGrouped).compactGroupedForm()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $editorRoute) { route in
            EditorSheet(route: route)
        }
        .confirmationDialog("Delete Journal?", isPresented: Binding(
            get: { confirmingJournalDelete != nil },
            set: { if !$0 { confirmingJournalDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let ledger = confirmingJournalDelete {
                    store.deleteJournal(ledger.id)
                }
                confirmingJournalDelete = nil
            }
        }
        .confirmationDialog("Delete Currency?", isPresented: Binding(
            get: { confirmingCurrencyDelete != nil },
            set: { if !$0 { confirmingCurrencyDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let currency = confirmingCurrencyDelete {
                    store.deleteCurrency(currency.id)
                }
                confirmingCurrencyDelete = nil
            }
        }

    }
}

struct SettingsIconLabel: View {
    var title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .resizable().scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }
}

struct CloudSyncManagementView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var syncState: MobileCloudSyncState
    @State private var showingConnection = false
    @State private var showingConflicts = false
    @State private var confirmingReset = false

    var body: some View {
        FinanceForm {
            FinanceFormCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: Binding(get: { store.data.syncEnabled }, set: { store.setSyncEnabled($0) })) {
                        Text("Cloud Sync").font(.title)
                    }
                    .tint(.green)
                    .accessibilityIdentifier("cloud-sync-toggle")
                    Text("Keep your data up-to-date between your iPhone, iPad and Mac. Data is securely stored on iCloud.")
                        .font(.body).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("STATUS").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 20)
                FinanceFormCard {
                    FinanceFormRow(last: true) {
                        if store.cloudSyncConflicts.isEmpty {
                            if syncState.progress.isRunning {
                                CloudSyncRunningStatus(progress: syncState.progress)
                            } else {
                                Text(cloudSyncStatusText).foregroundStyle(.primary)
                            }
                        } else {
                            Button { showingConflicts = true } label: {
                                FinanceFormLabel(title: "Changes Need Review", value: "\(store.cloudSyncConflicts.count)")
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("cloud-sync-status")
            }

            FinanceFormCard {
                FinanceFormRow {
                    Button("Synchronize Now") { store.synchronizeNow() }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .disabled(!store.data.syncEnabled || syncState.progress.isRunning)
                }
                FinanceFormRow(last: true) {
                    Button("Reset...", role: .destructive) { confirmingReset = true }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        .disabled(!canResetCloudSync)
                }
            }
        }
        .navigationTitle("Cloud Sync")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingConnection = true } label: {
                    Image(systemName: "questionmark.circle").font(.title2)
                }.accessibilityLabel("Cloud Sync Help")
            }
        }
        .sheet(isPresented: $showingConnection) { CloudSyncSettingsView() }
        .sheet(isPresented: $showingConflicts) {
            NavigationStack {
                List { MobileCloudSyncConflictsSection() }
                    .navigationTitle("Review Changes").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingConflicts = false } } }
            }
        }
        .confirmationDialog("Reset Cloud Sync?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Local Sync State", role: .destructive) { Task { await store.resetCloudSyncAsync() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This resets the sync connection on this device. Your journals and iCloud data are kept.")
        }
    }

    private var cloudSyncStatusText: String {
        switch syncState.progress.state {
        case .idle: store.data.syncEnabled ? "Ready to Sync" : "Sync Disabled"
        case .running: syncState.progress.phase.title
        case .succeeded: "Up to date"
        case .failed: "Sync failed"
        }
    }

    private var canResetCloudSync: Bool {
        !store.data.syncEnabled && store.cloudSyncDataAvailable && !syncState.progress.isRunning
    }
}

struct DisplaySettingsView: View {
    @EnvironmentObject private var store: MobileLedgerStore

    var body: some View {
        Form {
            Section {
                Picker("Date Format", selection: Binding(
                    get: { store.data.dateFormat },
                    set: { store.setDateFormat($0) }
                )) {
                    ForEach(AppDateFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                Picker("Appearance", selection: Binding(
                    get: { store.data.appearance },
                    set: { store.setAppearance($0) }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
        .compactGroupedForm()
    }
}

struct SecuritySettingsView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""

    var body: some View {
        Form {
            Section {
                Label(store.isPasswordLockEnabled ? "Password Lock is enabled" : "Password Lock is off", systemImage: store.isPasswordLockEnabled ? "lock.fill" : "lock.open")
                    .foregroundStyle(store.isPasswordLockEnabled ? .green : .secondary)
                Text("Password locking protects this iPhone app session. Your data remains stored locally, in backups, and in Cloud Sync if enabled.")
                    .foregroundStyle(.secondary)
            }

            if store.isPasswordLockEnabled {
                Section("Current Password") {
                    SecureField("Password", text: $currentPassword)
                        .textContentType(.password)

                    Button {
                        store.lockApp()
                        currentPassword = ""
                    } label: {
                        Label("Lock Now", systemImage: "lock")
                    }

                    Button(role: .destructive) {
                        store.disablePasswordLock(password: currentPassword)
                        if store.validationError == nil {
                            currentPassword = ""
                        }
                    } label: {
                        Label("Disable Password Lock", systemImage: "lock.open")
                    }
                    .disabled(currentPassword.isEmpty)
                }
            } else {
                Section("Set Password") {
                    SecureField("New Password", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("Verify Password", text: $confirmPassword)
                        .textContentType(.newPassword)

                    Button {
                        store.setPasswordLock(password: newPassword, confirmation: confirmPassword)
                        if store.validationError == nil {
                            newPassword = ""
                            confirmPassword = ""
                        }
                    } label: {
                        Label("Set Password", systemImage: "lock")
                    }
                    .disabled(newPassword.isEmpty || confirmPassword.isEmpty)
                }
            }
        }
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .compactGroupedForm()
    }
}

struct BackupSettingsView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var backup = MobileBackupController.shared
    @State private var showingImporter = false
    @State private var pendingImport: URL?
    @State private var sharing: SharedBackupFile?

    var body: some View {
        Form {
            Section {
                Button { backup.export(using: store) } label: {
                    Label("Export Backup", systemImage: "square.and.arrow.up")
                }.disabled(backup.isRunning)
                if let file = backup.readyFile {
                    Button { sharing = file } label: {
                        Label("Share Prepared Backup", systemImage: "square.and.arrow.up.on.square")
                    }.disabled(backup.isRunning)
                }
                Button { showingImporter = true } label: {
                    Label("Import Backup", systemImage: "square.and.arrow.down")
                }.disabled(backup.isRunning)
            }
            if backup.isRunning {
                Section {
                    ProgressView(backup.title, value: backup.fraction)
                    Text("You can leave this screen while preparation continues. Editing pauses until backup preparation finishes.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Cancel", role: .cancel) { backup.cancel() }
                }.accessibilityIdentifier("backup-progress")
            }
            Section("Included") {
                Label("\(store.orderedLedgers.count) Journals", systemImage: "folder")
                Label("\(store.data.accounts.count) Accounts", systemImage: "list.bullet.rectangle")
                Label("\(store.data.transactions.count) Transactions", systemImage: "arrow.left.arrow.right")
                Label("\(store.data.transactionTemplates.count) Templates", systemImage: "doc.text")
                Label("\(store.backupAttachmentCount) Attachments", systemImage: "paperclip")
            }
            Section {
                Text("Backups include all journals and receipt files in a ZIP. Use the share sheet to save to Files, Dropbox, or another destination. Restoring replaces the current journals and turns Cloud Sync off.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Backup").navigationBarTitleDisplayMode(.inline)
        .compactGroupedForm()
        .onAppear {
            backup.loadPreparedBackup(using: store)
            presentPreparedBackup()
        }
        .onChange(of: backup.readyFile?.id) { presentPreparedBackup() }
        .onChange(of: scenePhase) { presentPreparedBackup() }
        .onChange(of: store.requiresUnlock) { presentPreparedBackup() }
        .sheet(item: $sharing) { file in
            BackupShareSheet(url: file.url) { completed, error in
                sharing = nil
                if let error { backup.statusMessage = "Sharing failed: \(error.localizedDescription)" }
                else if completed { backup.statusMessage = "Backup shared." }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.financesMobileBackup, .financesBackupPackage, .financesCompressedBackup, .json, .item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pendingImport = url
            case .failure(let error): backup.statusMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Replace Current Journals?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), titleVisibility: .visible) {
            if let url = pendingImport {
                Button("Restore Backup", role: .destructive) { pendingImport = nil; backup.restore(from: url, using: store) }
            }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text("Restore \(pendingImport?.lastPathComponent ?? "this backup")? This replaces all current journals and attachments. Export a backup first if you want to keep them.")
        }
        .alert("Backup", isPresented: Binding(get: { backup.statusMessage != nil }, set: { if !$0 { backup.statusMessage = nil } })) {
            Button("OK") { backup.statusMessage = nil }
        } message: { Text(backup.statusMessage ?? "") }
    }

    private func presentPreparedBackup() {
        guard scenePhase == .active, !store.requiresUnlock, backup.shouldPresentShare, let file = backup.readyFile else { return }
        backup.shouldPresentShare = false
        sharing = file
    }
}

struct FinancesForMacView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var syncState: MobileCloudSyncState

    var body: some View {
        Form {
            Section("iCloud Sync") {
                if syncState.progress.isRunning {
                    CloudSyncRunningStatus(progress: syncState.progress)
                } else {
                    Label(syncStatusTitle, systemImage: syncStatusIcon)
                        .foregroundStyle(syncStatusColor)
                    if let detail = syncState.progress.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    store.synchronizeNow()
                } label: {
                    Label("Synchronize Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!store.data.syncEnabled || syncState.progress.isRunning)
            }

            Section("Connection") {
                LabeledContent("Service", value: "iCloud / CloudKit")
                Text("Use the same Apple Account for iCloud on each device.")
                LabeledContent("Sync", value: store.data.syncEnabled ? "Enabled" : "Disabled")
            }

            Section("Current Data") {
                Label("\(store.orderedLedgers.count) Journals", systemImage: "folder")
                Label("\(store.data.transactions.count) Transactions", systemImage: "arrow.left.arrow.right")
                Label("\(store.backupAttachmentCount) Attachments", systemImage: "paperclip")
            }
        }
        .navigationTitle("Finances for Mac")
        .navigationBarTitleDisplayMode(.inline)
        .compactGroupedForm()
    }

    private var syncStatusTitle: String {
        switch syncState.progress.state {
        case .idle:
            store.data.syncEnabled ? "Ready to Sync" : "Sync Disabled"
        case .running:
            syncState.progress.message.isEmpty ? "Synchronizing" : syncState.progress.message
        case .succeeded:
            "Up to date"
        case .failed:
            syncState.progress.message.isEmpty ? "Sync failed" : syncState.progress.message
        }
    }

    private var syncStatusIcon: String {
        switch syncState.progress.state {
        case .failed:
            "icloud.slash"
        case .running:
            syncState.progress.phase.symbol
        case .idle, .succeeded:
            store.data.syncEnabled ? "icloud" : "icloud.slash"
        }
    }

    private var syncStatusColor: Color {
        switch syncState.progress.state {
        case .failed:
            .red
        case .running:
            .blue
        case .idle, .succeeded:
            store.data.syncEnabled ? .green : .secondary
        }
    }
}

struct HelpSettingsView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var copiedDiagnostics = false

    var body: some View {
        Form {
            Section("Transactions") {
                helpRow(
                    "Balanced postings",
                    "Every transaction needs at least two postings, and totals must balance to zero for each currency.",
                    "equal.circle"
                )
                helpRow(
                    "Swipe actions",
                    "Swipe left to duplicate or delete. Swipe right to mark an entry cleared or uncleared.",
                    "hand.draw"
                )
            }

            Section("Accounts") {
                helpRow(
                    "Groups",
                    "Accounts can be nested inside matching account-type groups.",
                    "folder"
                )
                helpRow(
                    "Colors",
                    "Income and expense accounts carry colors in transaction flow views.",
                    "paintpalette"
                )
            }

            Section("Sync and Backup") {
                helpRow(
                    "iCloud Sync",
                    "iCloud sync keeps journals, transactions, templates, and attachments aligned with the Mac app.",
                    "icloud"
                )
                helpRow(
                    "Backups",
                    "Backups include journal data and local attachment files.",
                    "externaldrive"
                )
            }

            Section("Diagnostics") {
                Button {
                    UIPasteboard.general.string = diagnosticSummary
                    copiedDiagnostics = true
                } label: {
                    Label("Copy Diagnostic Summary", systemImage: "doc.on.doc")
                }

                if copiedDiagnostics {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
        .compactGroupedForm()
    }

    private func helpRow(_ title: String, _ body: String, _ systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var diagnosticSummary: String {
        [
            "Finances Mobile \(appVersion) (\(appBuild))",
            "Journals: \(store.orderedLedgers.count)",
            "Accounts: \(store.data.accounts.count)",
            "Transactions: \(store.data.transactions.count)",
            "Templates: \(store.data.transactionTemplates.count)",
            "Attachments: \(store.backupAttachmentCount)",
            "Sync enabled: \(store.data.syncEnabled)",
            "Sync state: \(store.cloudSyncProgress.state)"
        ].joined(separator: "\n")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct CloudSyncSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: MobileLedgerStore
    @EnvironmentObject private var syncState: MobileCloudSyncState

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud") {
                    Text("Sign in to the same Apple Account for iCloud on your iPhone, iPad, and Macs. Enable iCloud Drive and allow Finances to use iCloud in system settings.")
                    Text("Journals and receipts sync to your private iCloud database. They count against your iCloud storage.")
                    Text("Sync requires a signed app provisioned for the Finances CloudKit container. Local and unsigned builds can still manage journals and backups.")
                }
                if let detail = syncState.progress.detail, !detail.isEmpty {
                    Section("Sync Details") { Text(detail).font(.footnote).textSelection(.enabled) }
                }
            }
            .navigationTitle("About iCloud Sync")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
