import Observation
import SwiftUI

/// RPCN, RPCS3's online service, as desktop's RPCN dialog sets it up (rpcs3_ios_rpcn in core/rpcs3_ios.h).
struct RPCNAccount: Decodable {
    struct Host: Decodable, Hashable {
        let name: String
        let host: String
    }

    let username: String
    let hasPassword: Bool
    let token: String
    let host: String
    let hosts: [Host]

    var isSetUp: Bool { !username.isEmpty && hasPassword }

    static func load() -> RPCNAccount? { CoreCall.decode(RPCNAccount.self, core_rpcn()) }
}

@Observable
@MainActor
final class RPCNStore {
    private(set) var account = RPCNAccount.load()
    private(set) var busy: String?
    var message: String?
    private let settings = SettingsStore(gameID: nil, gameTitle: nil)

    /// Games go online through RPCN: internet connected and PSN status RPCN.
    var isOnline: Bool {
        settings.setting(["Net", "PSN status"])?.value == "RPCN" && settings.setting(["Net", "Internet enabled"])?.value == "Connected"
    }

    func setOnline(_ online: Bool) {
        if online {
            if let internet = settings.setting(["Net", "Internet enabled"]) { settings.set(internet, to: "Connected") }
            if let psn = settings.setting(["Net", "PSN status"]) { settings.set(psn, to: "RPCN") }
        } else if let psn = settings.setting(["Net", "PSN status"]) {
            settings.set(psn, to: "Disconnected")
        }
        settings.reload()
        if let error = settings.lastError { message = error; settings.lastError = nil }
    }

    func reload() {
        account = RPCNAccount.load()
        settings.reload()
    }

    func setHost(_ host: String) {
        _ = core_rpcn_set_host(host)
        reload()
    }

    func addHost(name: String, host: String) {
        message = CoreCall.message { core_rpcn_add_host(name, host, $0, $1) }
        reload()
    }

    func removeHost(_ host: RPCNAccount.Host) {
        _ = core_rpcn_remove_host(host.name, host.host)
        reload()
    }

    /// Saves an existing account's details; nil when it worked.
    func setAccount(username: String, password: String, token: String) -> String? {
        let error = CoreCall.message { core_rpcn_set_account(username, password, token, $0, $1) }
        reload()
        return error
    }

    /// Runs a call that reaches the server off the main thread, then shows what it said.
    func contact(_ what: String, _ call: @escaping @Sendable (UnsafeMutablePointer<CChar>, Int) -> Int32, then: ((Bool) -> Void)? = nil) {
        guard busy == nil else { return }
        busy = what
        Task {
            let (code, text) = await Task.detached {
                var buffer = [CChar](repeating: 0, count: 1024)
                let code = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
                return (code, String(cString: buffer))
            }.value
            busy = nil
            message = text.isEmpty ? (code == 0 ? "Done." : "It did not work. See RPCS3.log.") : text
            reload()
            then?(code == 0)
        }
    }
}

struct RPCNView: View {
    @State private var store = RPCNStore()
    @State private var form: AccountForm.Mode?
    @State private var addingServer = false
    @State private var serverName = ""
    @State private var serverHost = ""
    @State private var deleting = false
    @State private var deleteConfirmation = ""
    @State private var changingPassword = false

    var body: some View {
        List {
            Section {
                Toggle("Play Online with RPCN", isOn: Binding(get: { store.isOnline }, set: { store.setOnline($0) }))
                    .disabled(store.account?.isSetUp != true && !store.isOnline)
            } footer: {
                Text(store.account?.isSetUp == true
                     ? "Games that play online connect through RPCN, RPCS3's own online service. Changes apply from the next start of a game."
                     : "Set up an RPCN account first. RPCN is RPCS3's own online service; the PlayStation Network itself is not available.")
            }

            if let account = store.account {
                accountSection(account)
                serverSection(account)
            }
        }
        .navigationTitle("RPCN")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.busy != nil)
        .overlay {
            if let busy = store.busy {
                ProgressView(busy)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear { store.reload() }
        .sheet(item: $form) { mode in
            AccountForm(store: store, mode: mode)
        }
        .sheet(isPresented: $changingPassword) {
            PasswordReset(store: store)
        }
        .alert("Add Server", isPresented: $addingServer) {
            TextField("Name", text: $serverName)
            TextField("Address (host or host:port)", text: $serverHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {}
            Button("Add") { store.addHost(name: serverName, host: serverHost) }
        }
        .alert("Delete the account \(store.account?.username ?? "")?", isPresented: $deleting) {
            TextField("Type the username to confirm", text: $deleteConfirmation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Delete Account", role: .destructive) {
                guard deleteConfirmation == store.account?.username else {
                    store.message = "The username did not match; nothing was deleted."
                    return
                }
                store.contact("Deleting the account…") { core_rpcn_delete_account($0, $1) }
            }
        } message: {
            Text("The account is deleted on the server for good, with its friends and online data.")
        }
        .alert("RPCN", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.message ?? "")
        }
    }

    @ViewBuilder private func accountSection(_ account: RPCNAccount) -> some View {
        Section {
            if account.isSetUp {
                LabeledContent("Username", value: account.username)
                LabeledContent("Activated", value: account.token.isEmpty ? "No (enter the token)" : "Yes")
                Button("Test Account", systemImage: "checkmark.shield") {
                    store.contact("Signing in…") { core_rpcn_test($0, $1) }
                }
                Button("Edit Account…", systemImage: "pencil") { form = .edit }
                if account.token.isEmpty {
                    Button("Send the Token Again", systemImage: "envelope") {
                        store.contact("Asking for the token…") { core_rpcn_resend_token($0, $1) }
                    }
                }
                Button("Change Password…", systemImage: "key") { changingPassword = true }
                Button("Delete Account…", systemImage: "trash", role: .destructive) {
                    deleteConfirmation = ""
                    deleting = true
                }
            } else {
                Button("Create Account…", systemImage: "person.badge.plus") { form = .create }
                Button("Use an Existing Account…", systemImage: "person.crop.circle") { form = .existing }
                if !account.username.isEmpty {
                    Button("Forgot Password…", systemImage: "key") { changingPassword = true }
                }
            }
        } header: {
            Text("Account")
        } footer: {
            if !account.isSetUp {
                Text("An account needs a username, a password and an email address; the server emails a token that activates it.")
            }
        }
    }

    @ViewBuilder private func serverSection(_ account: RPCNAccount) -> some View {
        Section {
            Picker("Server", selection: Binding(get: { account.host }, set: { store.setHost($0) })) {
                ForEach(account.hosts, id: \.self) { host in
                    Text(host.name).tag(host.host)
                }
            }
            ForEach(account.hosts.filter { $0.host != "np.rpcs3.net" }, id: \.self) { host in
                LabeledContent(host.name, value: host.host)
                    .swipeActions {
                        Button("Remove", role: .destructive) { store.removeHost(host) }
                    }
            }
            Button("Add Server…", systemImage: "plus") {
                serverName = ""
                serverHost = ""
                addingServer = true
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The official server is np.rpcs3.net. An account belongs to one server.")
        }
    }
}

/// Creating an account, or entering an existing one's details.
private struct AccountForm: View {
    enum Mode: String, Identifiable {
        case create, existing, edit
        var id: Self { self }
    }

    let store: RPCNStore
    let mode: Mode

    @State private var username = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var email = ""
    @State private var token = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(mode == .edit ? "Password (unchanged if empty)" : "Password", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                    if mode == .create {
                        SecureField("Password Again", text: $confirmation)
                            .textContentType(.newPassword)
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        TextField("Token (from the email)", text: $token)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                } footer: {
                    switch mode {
                    case .create:
                        Text("The username has 3 to 16 letters, digits, '-' or '_', and is case sensitive. The email is used only to send the token that activates the account, and password reset tokens.")
                    case .existing, .edit:
                        Text("The token activates the account; it is in the email the server sent when the account was created.")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle(mode == .create ? "New RPCN Account" : mode == .edit ? "Edit Account" : "RPCN Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .create ? "Create" : "Save") { submit() }
                        .disabled(username.isEmpty || (mode != .edit && password.isEmpty))
                }
            }
            .onAppear {
                if mode == .edit, let account = store.account {
                    username = account.username
                    token = account.token
                }
            }
        }
    }

    private func submit() {
        switch mode {
        case .create:
            guard password == confirmation else {
                error = "The passwords are not the same."
                return
            }
            let (name, secret, address) = (username, password, email)
            dismiss()
            store.contact("Creating the account…") { core_rpcn_create_account(name, secret, address, $0, $1) }
        case .existing, .edit:
            if let problem = store.setAccount(username: username, password: password, token: token.uppercased()) {
                error = problem
            } else {
                dismiss()
            }
        }
    }
}

/// Changing a forgotten password: a reset token by email, then the new password.
private struct PasswordReset: View {
    let store: RPCNStore

    @State private var username = ""
    @State private var email = ""
    @State private var token = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var hasToken = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("I Have a Reset Token", isOn: $hasToken)
                }
                if hasToken {
                    Section {
                        TextField("Reset Token", text: $token)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        SecureField("New Password", text: $password).textContentType(.newPassword)
                        SecureField("New Password Again", text: $confirmation).textContentType(.newPassword)
                        Button("Change Password") { changePassword() }
                            .disabled(username.isEmpty || token.isEmpty || password.isEmpty)
                    } footer: {
                        Text("The reset token is not the token that activated the account.")
                    }
                } else {
                    Section {
                        TextField("Email of the Account", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Send Reset Token") {
                            let (name, address) = (username, email)
                            store.contact("Asking for a reset token…", { core_rpcn_send_reset_token(name, address, $0, $1) }) { sent in
                                if sent { hasToken = true }
                            }
                        }
                        .disabled(username.isEmpty || email.isEmpty || store.busy != nil)
                    } footer: {
                        Text("The server emails a token for changing the password, once every 24 hours.")
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { username = store.account?.username ?? "" }
        }
    }

    private func changePassword() {
        guard password == confirmation else {
            error = "The passwords are not the same."
            return
        }
        let (name, code, secret) = (username, token.uppercased(), password)
        store.contact("Changing the password…", { core_rpcn_reset_password(name, code, secret, $0, $1) }) { changed in
            if changed { dismiss() }
        }
    }
}
