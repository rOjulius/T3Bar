import SwiftUI

struct SetupView: View {
    @Bindable var monitor: AgentMonitor

    @State private var mcpURLInput: String = ""
    @State private var manualTokenInput: String = ""
    @State private var showManualOption: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to T3 Code")
                    .font(.system(size: 13.5, weight: .semibold))
                Text("In T3 Code, open Settings → Sharing & access → \"Use in another app (MCP)\" (or Settings → Environments) and paste your /mcp URL.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("MCP Endpoint URL")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("https://.../mcp  or  http://127.0.0.1:.../mcp", text: $mcpURLInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11.5, design: .monospaced))
            }

            if showManualOption {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Bearer Token (optional)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    SecureField("Paste token or leave empty for local", text: $manualTokenInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                }
            }

            if let error = monitor.authError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if showManualOption {
                    Button {
                        monitor.connectWithManualToken(mcpURL: mcpURLInput, bearerToken: manualTokenInput)
                    } label: {
                        HStack(spacing: 6) {
                            if monitor.isAuthorizing {
                                ProgressView().controlSize(.small)
                            }
                            Text("Save & Connect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(monitor.isAuthorizing || mcpURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button {
                        monitor.connectWithOAuth(mcpURL: mcpURLInput)
                    } label: {
                        HStack(spacing: 6) {
                            if monitor.isAuthorizing {
                                ProgressView().controlSize(.small)
                            }
                            Text(monitor.isAuthorizing ? "Waiting for browser…" : "Sign in with T3 Code")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(monitor.isAuthorizing || mcpURLInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Button(showManualOption ? "Use OAuth sign-in instead" : "Use manual token / local URL") {
                    showManualOption.toggle()
                    monitor.authError = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                Spacer()

                if monitor.connectionState.isConnected || !monitor.savedMCPURL.isEmpty {
                    Button("Disconnect") {
                        monitor.disconnect()
                        mcpURLInput = ""
                        manualTokenInput = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red.opacity(0.85))
                }
            }
        }
        .padding(14)
        .onAppear {
            if mcpURLInput.isEmpty && !monitor.savedMCPURL.isEmpty {
                mcpURLInput = monitor.savedMCPURL
            }
            showManualOption = monitor.isConnectedWithManualToken
        }
    }
}
