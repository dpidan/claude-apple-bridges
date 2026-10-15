#!/usr/bin/env swift

// apple-bridges-mcp.swift
// Copyright © 2026 Tobias Stöger (tstoegi). Licensed under the MIT License.
// A minimal MCP server (stdio) so Claude Desktop and other MCP clients can run the bridges.
// Each installed bridge becomes one tool; its `args` array is passed to the binary unchanged.
// Usage:
//   apple-bridges-mcp   - Speak MCP over stdin/stdout (started by the MCP client, not by hand)

import Foundation

// MARK: - Bridges

/// One line per bridge. A bridge that is not installed is left out of tools/list.
let bridges: [(tool: String, binary: String, app: String)] = [
    ("reminders", "reminders-bridge", "Apple Reminders"),
    ("calendar",  "calendar-bridge",  "Apple Calendar"),
    ("contacts",  "contacts-bridge",  "Apple Contacts"),
    ("notes",     "notes-bridge",     "Apple Notes"),
    ("mail",      "mail-bridge",      "Apple Mail"),
    ("messages",  "messages-bridge",  "Apple Messages (iMessage/SMS)"),
    ("tmux",      "tmux-bridge",      "tmux sessions"),
]

/// The bridges are installed next to this server (INSTALL_DIR in the Makefile, ~/.claude by default).
let bridgeDir = Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()

func installedBridges() -> [(tool: String, binary: String, app: String)] {
    bridges.filter { FileManager.default.isExecutableFile(atPath: bridgeDir.appendingPathComponent($0.binary).path) }
}

/// Runs a bridge directly, without a shell, so every element of `args` stays one argument.
// ponytail: no timeout; a wedged Messages.app holds a call until AppleScript gives up (~2 min)
func run(_ binary: String, _ args: [String]) -> (output: String, exit: Int32) {
    let process = Process()
    process.executableURL = bridgeDir.appendingPathComponent(binary)
    process.arguments = args
    process.standardInput = FileHandle.nullDevice  // stdin is the MCP stream; a bridge must never read it
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return ("Error: cannot start \(binary): \(error.localizedDescription)", 127)
    }
    // Drain before waiting: large output (tmux snapshot) would otherwise fill the pipe and block forever
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

// MARK: - MCP

let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

let instructions = """
Each tool runs one Apple bridge CLI on this Mac. Pass the arguments exactly as on the command line, \
one array element per argument. `delete` commands are dry runs unless `--force` is passed; \
reminders `delete-list` has no dry run. mail `send` opens a compose window for review unless \
`--force` is passed. messages `send` delivers immediately and has no dry run.
"""

func toolList() -> [[String: Any]] {
    installedBridges().map { bridge in
        // Every bridge prints its usage when run without arguments, so new commands show up here unchanged
        let usage = run(bridge.binary, []).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "name": bridge.tool,
            "description": "Run \(bridge.binary) to work with \(bridge.app). Pass the CLI arguments in `args`.\n\n\(usage)",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "args": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Arguments after the binary name, one element per argument. No shell quoting needed.",
                    ],
                ],
                "required": ["args"],
            ],
        ]
    }
}

func send(_ message: [String: Any]) {
    // JSONSerialization never emits raw newlines, so one message is always one line
    var data = try! JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, _ result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(_ id: Any, _ code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func handle(_ method: String, _ params: [String: Any], id: Any) {
    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        reply(id, [
            "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[0],
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "apple-bridges", "version": "0.1.0"],
            "instructions": instructions,
        ])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": toolList()])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        guard let bridge = installedBridges().first(where: { $0.tool == name }) else {
            return fail(id, -32602, "Unknown tool: \(name)")
        }
        guard let args = (params["arguments"] as? [String: Any])?["args"] as? [String] else {
            return fail(id, -32602, "`args` must be an array of strings")
        }
        let result = run(bridge.binary, args)
        reply(id, [
            "content": [["type": "text", "text": result.output]],
            "isError": result.exit != 0,
        ])
    default:
        fail(id, -32601, "Method not found: \(method)")
    }
}

// MARK: - Entry point

while let line = readLine() {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
        fail(NSNull(), -32700, "Parse error")
        continue
    }
    // Notifications carry no id and get no response; nor do client responses, which carry no method
    guard let id = message["id"], let method = message["method"] as? String else { continue }
    handle(method, message["params"] as? [String: Any] ?? [:], id: id)
}
