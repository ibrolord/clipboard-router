import ClipboardRouterCore
import SwiftUI

struct EncryptedSharePreviewSheet: View {
    let content: ClipContent
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Decrypted Clipboard Router Share", systemImage: "lock.open")
                .font(.title2.weight(.semibold))
            Text("Authentication succeeded. This plaintext is ephemeral and has not been written to History or the clipboard.")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(content.text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(minHeight: 150, maxHeight: 340)
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy Decrypted", systemImage: "doc.on.doc") { copy() }
                    .buttonStyle(.borderedProminent)
                    .help("Explicitly write the decrypted typed payload to the clipboard")
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

struct EncryptedShareComposerSheet: View {
    @ObservedObject var model: AppModel
    let request: EncryptedShareRequest
    let dismiss: () -> Void
    @State private var recipientKey = ""
    @State private var localRecipientKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Encrypted Clipboard Router Share", systemImage: "lock.shield")
                .font(.title2.weight(.semibold))
            Text("Source: \(request.title)")
                .font(.headline)
            Text("The clip is sealed with Curve25519 + AES-GCM. Paste the recipient's authenticated public key below. Clipboard Router does not discover or trust keys automatically.")
                .foregroundStyle(.secondary)
            if let localRecipientKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your recipient key — give this to senders")
                        .font(.headline)
                    Text(localRecipientKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .help("Select and copy this public key so another Clipboard Router installation can encrypt a share to you")
            }
            Text("Recipient public key")
                .font(.headline)
            TextField("clipboard-router-recipient-key:v1:…", text: $recipientKey, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .lineLimit(2...4)
            if let envelope = model.encryptedShareEnvelope {
                Text("Opaque encrypted envelope")
                    .font(.headline)
                ScrollView {
                    Text(envelope)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .frame(maxHeight: 130)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if model.encryptedShareEnvelope != nil {
                    Button("Copy Envelope", systemImage: "doc.on.doc") {
                        model.copyEncryptedShareEnvelope()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Encrypt Share", systemImage: "lock") {
                        model.generateEncryptedShare(for: request, recipientKeyString: recipientKey)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || recipientKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if request.quarantineID != nil, model.encryptedShareEnvelope != nil {
                    Button("Move Source to Vault", systemImage: "lock") {
                        model.moveEncryptedShareSourceToVault()
                    }
                    .help("Remove the quarantined source from memory after encrypting it into Vault")
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .task {
            localRecipientKey = await model.localSecureSharePublicKeyString()
        }
    }
}
