//
//  Shell.swift
//  PlayCover
//

import Foundation

class Shell: ObservableObject {
    @discardableResult
    static func run(print: Bool = true, _ binary: String, _ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        if print {
            Log.shared.log(String(data: output, encoding: .utf8) ?? "Shell error occured")
        }

        process.waitUntilExit()
        let status = process.terminationStatus
        if status != 0 {
            throw String(data: output, encoding: .utf8) ?? "Shell error occured"
        }
        return String(data: output, encoding: .utf8) ?? "Shell error occured"
    }

    static func runSu(_ args: [String], _ argc: String) -> Bool {
        let password = argc
        let passwordWithNewline = password + "\n"
        let sudo = Process()
        sudo.launchPath = "/usr/bin/sudo"
        sudo.arguments = args
        let sudoIn = Pipe()
        let sudoOut = Pipe()
        sudo.standardOutput = sudoOut
        sudo.standardError = sudoOut
        sudo.standardInput = sudoIn
        sudo.launch()

        var result = true

        // Show the output as it is produced
        sudoOut.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.count == 0 { return }

            if let out = String(bytes: data, encoding: .utf8) {
                Log.shared.log(out)
                if out.contains("password") {
                    result = false
                }
            }
        }
        if let data = passwordWithNewline.data(using: .utf8) {
            // Write the password
            sudoIn.fileHandleForWriting.write(data)

            // Close the file handle after writing the password; avoids a
            // hang for incorrect password.
            try? sudoIn.fileHandleForWriting.close()
        }

        // Make sure we don't disappear while output is still being produced.
        sudo.waitUntilExit()
        return result
    }

    static func signMacho(_ binary: URL) throws {
        try run("/usr/bin/codesign", "-fs-", binary.path)
    }

    /// Signs every embedded framework/dylib/bundle *inside* the app payload first,
    /// then signs the main bundle with the given entitlements. This guarantees a
    /// proper recursive (bottom-up) signature: `--deep` alone seals nested code in
    /// an arbitrary order and can leave frameworks invalid when the outer bundle
    /// is re-signed later (which kills media apps like Alight Motion on launch
    /// because PlayTools/AVFoundation helpers fail library validation).
    static func signAppWith(_ exec: URL, entitlements: URL) throws {
        let appBundle = exec.deletingLastPathComponent()
        try signNestedCode(in: appBundle)
        try run("/usr/bin/codesign", "-fs-", appBundle.path,
                "--deep", "--entitlements", entitlements.path)
    }

    static func signApp(_ exec: URL) throws {
        let appBundle = exec.deletingLastPathComponent()
        try signNestedCode(in: appBundle)
        try run("/usr/bin/codesign", "-fs-", appBundle.path,
                "--deep", "--preserve-metadata=entitlements")
    }

    /// Bottom-up ad-hoc signing of nested Mach-O code (frameworks, dylibs, xpc,
    /// app extensions, PlugIns bundles), deepest components first.
    private static func signNestedCode(in appBundle: URL) throws {
        let nestedRoots = [
            appBundle.appendingPathComponent("Frameworks"),
            appBundle.appendingPathComponent("PlugIns"),
            appBundle.appendingPathComponent("XPCServices"),
            appBundle.appendingPathComponent("Extensions"),
            // Catalyst-style payloads keep PlayTools next to the executable too
            execDirectoryFallback(appBundle)
        ]

        for root in nestedRoots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            // Sort by path depth descending so containers get signed after their contents
            let urls = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [])?.compactMap { $0 as? URL } ?? []
            let candidates = urls.filter { url in
                let ext = url.pathExtension
                return ext == "framework" || ext == "bundle" || ext == "dylib"
                    || ext == "xpc" || ext == "app"
            }.sorted { $0.path.count > $1.path.count }

            for url in candidates {
                if url.pathExtension == "framework" {
                    // Sign the versioned binary first, then the framework wrapper
                    let versionsBinary = url
                        .appendingPathComponent("Versions/A/\(url.deletingPathExtension().lastPathComponent)")
                    if FileManager.default.fileExists(atPath: versionsBinary.path) {
                        _ = try? run("/usr/bin/codesign", "-fs-", versionsBinary.path)
                    }
                    try? run("/usr/bin/codesign", "-fs-", url.path)
                } else {
                    try? run("/usr/bin/codesign", "-fs-", url.path)
                }
            }
        }
    }

    private static func execDirectoryFallback(_ appBundle: URL) -> URL {
        appBundle.appendingPathComponent("MacOS")
    }

    static func setMetalHUD(_ bundleID: String, enabled: Bool) throws {
        try run("/usr/bin/defaults", "write", bundleID,
                      "MetalForceHudEnabled", "-bool", String(enabled))
    }

    static func lldb(_ url: URL, withTerminalWindow: Bool = false) throws {
        Task(priority: .utility) {
            if withTerminalWindow {
                let command = "/usr/bin/lldb -o run \(url.esc) -o exit"
                    .replacingOccurrences(of: "\\", with: "\\\\")
                let osascript = """
                    tell app "Terminal"
                        reopen
                        activate
                        do script "\(command)"
                    end tell
                """
                let appleScript = NSAppleScript(source: osascript)
                var possibleError: NSDictionary?
                appleScript?.executeAndReturnError(&possibleError)

                if let error = possibleError {
                    for key in error.allKeys {
                        if let key = key as? String {
                            throw error.value(forKey: key).debugDescription
                        }
                    }
                }
            } else {
                try run("/usr/bin/lldb", "-o", "run", url.path, "-o", "exit")
            }
        }
    }
}

extension Swift.String: Swift.Error { }

extension Swift.String: Foundation.LocalizedError {
    public var errorDescription: String? { self }
}
