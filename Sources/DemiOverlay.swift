import AppKit
import Foundation
import SwiftUI

struct DemiRegistryFile: Decodable, Sendable {
    let claudeDefaults: [String: String]
    let sessions: [DemiRegistrySession]
}

struct DemiRegistrySession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let tmuxSession: String
    let repoPath: String
    let shellAlias: String?
    let claudeCommand: String?
    let workspaceRole: String?
    let agentRunManaged: Bool?
    let platform: [String]?

    var supportsMac: Bool {
        guard let platform else { return true }
        return platform.contains("macos") || platform.contains("shell")
    }

    var isLaunchable: Bool {
        supportsMac && workspaceRole != "view"
    }

    var role: String {
        workspaceRole ?? "project"
    }
}

struct DemiCmuxSyncSummary: Equatable, Sendable {
    var registryURL: URL
    var configURL: URL
    var sessionCount: Int
    var wroteConfig: Bool
}

struct DemiLaunchContext: Equatable, Sendable {
    let title: String
    let workingDirectory: String
    let command: String
}

enum DemiCmuxError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

enum DemiOverlaySettings {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DEMI_C_OVERLAY"] != "0"
    }
}

enum DemiCmuxConfigSync {
    static let repoRoot = URL(
        fileURLWithPath: "/Volumes/vFAST-4T/MAIN-REPO/Vault/FoundationOS",
        isDirectory: true
    )

    static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/demi-c/cmux.json")
    }

    static var launchScriptsDirectory: URL {
        defaultConfigURL.deletingLastPathComponent()
            .appendingPathComponent("launch", isDirectory: true)
    }

    static var registryCandidates: [URL] {
        [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".second-foundation/config/session-registry.json"),
            repoRoot.appendingPathComponent("DEMI/config/session-registry.json")
        ]
    }

    static func syncAtLaunchIfPossible() {
        guard DemiOverlaySettings.isEnabled else { return }
        _ = try? syncConfigFromRegistry()
    }

    static func syncConfigFromRegistry(configURL: URL = defaultConfigURL) throws -> DemiCmuxSyncSummary {
        let loaded = try loadRegistry()
        let launchableCount = loaded.registry.sessions.filter(\.isLaunchable).count
        let json = try buildConfigJSONString(for: loaded.registry)
        let wrote = try writeIfChanged(json, to: configURL)
        return DemiCmuxSyncSummary(
            registryURL: loaded.fileURL,
            configURL: configURL,
            sessionCount: launchableCount,
            wroteConfig: wrote
        )
    }

    static func defaultLaunchContext() -> DemiLaunchContext? {
        guard DemiOverlaySettings.isEnabled else { return nil }
        guard let loaded = try? loadRegistry() else { return nil }
        let defaultSession = loaded.registry.sessions.first { $0.id == "demi" && $0.isLaunchable }
            ?? loaded.registry.sessions.first { $0.isLaunchable }
        guard let defaultSession else { return nil }
        guard let scriptURL = try? ensureLaunchScript(for: defaultSession, registry: loaded.registry) else {
            return nil
        }
        return DemiLaunchContext(
            title: defaultSession.displayName,
            workingDirectory: defaultSession.repoPath,
            command: scriptURL.path
        )
    }

    static func defaultLaunchCommand() -> String? {
        defaultLaunchContext()?.command
    }

    static func loadRegistry() throws -> (fileURL: URL, registry: DemiRegistryFile) {
        var failures: [String] = []
        for fileURL in registryCandidates where FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                let decoded = try JSONDecoder().decode(DemiRegistryFile.self, from: data)
                return (fileURL, decoded)
            } catch {
                failures.append("\(fileURL.path): \(error.localizedDescription)")
            }
        }

        throw DemiCmuxError.message(
            failures.isEmpty
                ? "Could not find DEMI session-registry.json."
                : "Could not open DEMI session registry. \(failures.joined(separator: " | "))"
        )
    }

    static func buildConfigJSONString(for registry: DemiRegistryFile) throws -> String {
        let launchable = registry.sessions.filter(\.isLaunchable)
        var actions: [String: Any] = [:]
        var contextMenu: [Any] = []
        var commands: [[String: Any]] = []
        let defaultWorkspaceCommandName = launchable.first(where: { $0.id == "demi" })
            .map { "DEMI: \($0.displayName)" }

        for session in launchable {
            let commandName = "DEMI: \(session.displayName)"
            let actionID = "demi.session.\(session.id)"
            actions[actionID] = [
                "type": "workspaceCommand",
                "commandName": commandName,
                "title": session.displayName,
                "subtitle": "\(session.role) - \(shortPath(session.repoPath))",
                "keywords": compactStrings([
                    "demi",
                    session.id,
                    session.tmuxSession,
                    session.shellAlias,
                    session.role
                ]),
                "icon": [
                    "type": "symbol",
                    "name": iconName(for: session)
                ]
            ]

            if contextMenu.count < 8 {
                contextMenu.append(actionID)
            }

            commands.append([
                "name": commandName,
                "description": "Open \(session.displayName) with DEMI's configured Claude command.",
                "keywords": compactStrings([
                    "demi",
                    session.id,
                    session.displayName,
                    session.tmuxSession,
                    session.shellAlias
                ]),
                "restart": "ignore",
                "workspace": [
                    "name": session.displayName,
                    "cwd": session.repoPath,
                    "color": color(for: session),
                    "layout": [
                        "pane": [
                            "surfaces": [
                                [
                                    "type": "terminal",
                                    "name": "Claude",
                                    "cwd": session.repoPath,
                                    "command": try launchScriptCommand(for: session, registry: registry),
                                    "focus": true
                                ],
                                [
                                    "type": "terminal",
                                    "name": "Shell",
                                    "cwd": session.repoPath
                                ]
                            ]
                        ]
                    ]
                ]
            ])
        }

        contextMenu.append(["type": "separator"])
        contextMenu.append("cmux.newTerminal")
        contextMenu.append("cmux.newBrowser")

        var config: [String: Any] = [
            "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
            "schemaVersion": 1,
            "actions": actions,
            "ui": [
                "newWorkspace": [
                    "contextMenu": contextMenu
                ]
            ],
            "commands": commands
        ]
        if let defaultWorkspaceCommandName {
            config["newWorkspaceCommand"] = defaultWorkspaceCommandName
        }

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw DemiCmuxError.message("Could not encode DEMI-C cmux config.")
        }
        return json + "\n"
    }

    private static func launchScriptCommand(for session: DemiRegistrySession, registry: DemiRegistryFile) throws -> String {
        try ensureLaunchScript(for: session, registry: registry).path
    }

    private static func ensureLaunchScript(for session: DemiRegistrySession, registry: DemiRegistryFile) throws -> URL {
        let fileURL = launchScriptsDirectory
            .appendingPathComponent(safeFileName(session.id))
            .appendingPathExtension("sh")
        let script = """
        #!/bin/bash
        set -e
        \(launchCommand(for: session, registry: registry))
        """
        let wrote = try writeIfChanged(script + "\n", to: fileURL)
        if wrote || !FileManager.default.isExecutableFile(atPath: fileURL.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: fileURL.path
            )
        }
        return fileURL
    }

    private static func writeIfChanged(_ string: String, to url: URL) throws -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == string {
            return false
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try string.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    private static func launchCommand(for session: DemiRegistrySession, registry: DemiRegistryFile) -> String {
        let commandKey = session.claudeCommand ?? "standard"
        let claudeCommand = registry.claudeDefaults[commandKey]
            ?? registry.claudeDefaults["standard"]
            ?? "/Users/main/.second-foundation/bin/claude-vfast --chrome --effort max --permission-mode bypassPermissions"
        let exports = [
            "export DEMI_SESSION_ID=\(shellQuoted(session.id))",
            "export DEMI_TMUX_SESSION=\(shellQuoted(session.tmuxSession))",
            "export DEMI_WORKSPACE_ROLE=\(shellQuoted(session.role))"
        ].joined(separator: "; ")
        return "\(exports); cd \(shellQuoted(session.repoPath)) && exec \(claudeCommand)"
    }

    private static func safeFileName(_ value: String) -> String {
        let safe = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return safe.isEmpty ? "demi-session" : safe
    }

    private static func compactStrings(_ values: [String?]) -> [String] {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func iconName(for session: DemiRegistrySession) -> String {
        switch session.role {
        case "control": return "brain.head.profile"
        case "utility": return "gearshape.2"
        case "recovery": return "clock.arrow.circlepath"
        default: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private static func color(for session: DemiRegistrySession) -> String {
        switch session.role {
        case "control": return "#0A84FF"
        case "utility": return "#30D158"
        case "recovery": return "#FF9F0A"
        default: return "#5E5CE6"
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + String(path.dropFirst(home.count))
        }
        let marker = "/MAIN-REPO/"
        if let range = path.range(of: marker) {
            return "MAIN-REPO/" + path[range.upperBound...]
        }
        return path
    }
}

@MainActor
final class DemiOverlayModel: ObservableObject {
    @Published private(set) var summary: DemiCmuxSyncSummary?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSyncing = false

    var statusText: String {
        if isSyncing { return "syncing registry" }
        if let errorMessage { return errorMessage }
        guard let summary else { return "waiting for registry" }
        let writeText = summary.wroteConfig ? "updated" : "current"
        return "\(summary.sessionCount) sessions - \(writeText)"
    }

    func syncAndReload() {
        isSyncing = true
        errorMessage = nil
        Task {
            do {
                let nextSummary = try await Task.detached(priority: .utility) {
                    try DemiCmuxConfigSync.syncConfigFromRegistry()
                }.value
                summary = nextSummary
                isSyncing = false
                AppDelegate.shared?.reloadCmuxConfigStores(source: "demi.overlay")
            } catch {
                summary = nil
                isSyncing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func revealConfig() {
        let url = summary?.configURL ?? DemiCmuxConfigSync.defaultConfigURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func openDemi() {
        let candidates = [
            "/Applications/DEMI.app",
            "\(NSHomeDirectory())/Applications/DEMI.app"
        ]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: DemiCmuxConfigSync.repoRoot.path, isDirectory: true))
        }
    }
}

struct DemiOverlayView: View {
    @StateObject private var model = DemiOverlayModel()
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(model.errorMessage == nil ? Color.blue : Color.red)
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("DEMI-C")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(model.statusText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(isExpanded ? "Hide" : "Show")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = model.summary {
                        Text("Registry")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        Text(DemiCmuxConfigSync.shortPath(summary.registryURL.path))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    HStack(spacing: 6) {
                        Button("Sync") {
                            model.syncAndReload()
                        }
                        .disabled(model.isSyncing)

                        Button("Config") {
                            model.revealConfig()
                        }

                        Button("DEMI") {
                            model.openDemi()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: isExpanded ? 260 : 210, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 14, x: 0, y: 8)
        .task {
            model.syncAndReload()
        }
    }
}
