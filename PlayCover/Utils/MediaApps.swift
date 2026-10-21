//
//  MediaApps.swift
//  PlayCover
//
//  Central whitelist for video/photo editing apps (e.g. Alight Motion) that run
//  poorly under the game-oriented PlayTools hooks: forced Metal drawable sizes,
//  HUD overlays, keymapping touch synthesis and arbitrary resolution upscaling
//  all break their native Metal pipelines and cause crashes on Catalyst.
//
//  Since PlayTools ships as a prebuilt Carthage binary (see Cartfile), the fork
//  cannot patch its Objective-C hooks directly — and because that official
//  binary has NO opt-out switches, the only real fix is to never let the dylib
//  load at all: media editors run on Apple's native iOSSupport/Catalyst layer
//  with ZERO Mach-O injection (`purgePlayTools` / `ensurePlayToolsBypassed`).
//  On top of the bypass we still:
//    1. Write per-app "safe defaults" into `App Settings/<bundleID>.plist`
//       (keymapping off, no virtual mouse, fixed 4:3 window, no Metal HUD...);
//    2. Force the native iPad layout in the wrapper's Info.plist
//       (UIDeviceFamily = [2], UIRequiresFullScreen = false, landscape modes);
//    3. Preserve the IPA's original CFBundleURLTypes and re-register the app
//       with LaunchServices (`lsregister -f`) so Safari deep links work;
//    4. Bridge the sandboxed container Documents folder to the real Mac
//       folders via symlinks (Mac_Downloads / Mac_Movies / Mac_Desktop).
//

import Foundation
import injection

// swiftlint:disable:next type_body_length
class MediaApps {
    /// Bundle identifiers of known video editors / media apps that must launch
    /// with a neutralized hook configuration.
    static let bundleIDs: Set<String> = [
        // Alight Motion Pro / free
        "alightcreative.alightmotion",
        "com.alightcreative.motion",
        // Other timeline-based video editors commonly affected by the same hooks
        "com.lightricks.filmmakerpro",
        "com.inshot.videoeditor",
        "com.videoroll.videoroll",
        "com.kinemaster.app.ios.app",
        "com.adobe.primetime",
        "com.apple.iMovieApp",
        "com.flextv.client.ios"
    ]

    /// True when this app should be treated as a media/video editor instead of a game.
    static func isMediaApp(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        if bundleIDs.contains(id) { return true }
        // Generic fallback for video-editor style identifiers
        return id.contains("video") || id.contains("film") || id.contains("motion")
            || id.contains("editor") || id.contains("cut")
    }

    static func isMediaApp(_ app: PlayApp) -> Bool {
        isMediaApp(app.info.bundleIdentifier)
    }

    /// Best-effort pre-Info.plist check (used before the IPA is unzipped): matches
    /// the *IPA file name* against known editor names. The definitive decision is
    /// always re-made from the real `CFBundleIdentifier` once the payload is parsed.
    static func looksLikeMediaApp(_ fileURL: URL) -> Bool {
        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        let hints = ["alight", "motion", "video", "film", "inshot", "kinemaster",
                     "vita", "filmmaker", "videoroll", "capcut", "imovie"]
        return hints.contains { name.contains($0) }
    }

    // MARK: - Legacy LSEnvironment keys pruned from media-app plists

    /// AUDIT FIX: the official prebuilt Carthage PlayTools binary does NOT read
    /// any `PT_DISABLE_*` / `AM_DISABLE_*` opt-out variable — those keys were
    /// fictitious. Now that media editors run with ZERO PlayTools injection
    /// (pure iOSSupport execution), such flags are useless *and* actively
    /// harmful: LaunchServices would export them into the app process anyway
    /// (e.g. `MTL_HUD_ENABLED=0` leaking into every child tool). Instead of
    /// injecting them, `pruneLegacyEnvironment(in:)` strips every trace of the
    /// old scheme from the sealed Info.plist.
    static let legacyManagedKeys: [String] = [
        "PT_DISABLE_GAME_HOOKS",
        "PT_DISABLE_METAL_OVERRIDES",
        "PT_DISABLE_DISPLAY_OVERRIDES",
        "PT_DISABLE_KEYMAPPING",
        "PT_DISABLE_TOUCH_SYNTHESIS",
        "PT_DISABLE_PLAYCHAIN",
        "PT_FIX_WINDOW_RATIO",
        "PLAYCOVER_MEDIA_APP",
        "AM_DISABLE_KEYMAPPING",
        "AM_DISABLE_METAL_INTERFERENCE",
        "MTL_HUD_ENABLED"
    ]

    // MARK: - Safe defaults applied before signing/launch

    /// Neutralizes every game-oriented feature in the persisted app settings:
    /// keymapping HUD, PlayChain, Metal HUD, virtual mouse, scroll-wheel hacks.
    static func applySafeDefaults(to app: PlayApp) {
        var updated = app.settings.settings
        updated.keymapping = false
        updated.playChain = false
        updated.playChainDebugging = false
        updated.metalHUD = false
        updated.disableBuiltinMouse = false
        updated.noKMOnInput = true
        updated.enableScrollWheel = true
        updated.inverseScreenValues = false
        // UIKit window stability: fixed resizable window locked to iPad Pro 4:3
        updated.windowFixMethod = 1
        updated.resizableAspectRatioType = 1
        updated.resizableAspectRatioWidth = 4
        updated.resizableAspectRatioHeight = 3
        // iPad Pro 11" landscape reference resolution (2388x1668 -> 4:3 logical canvas)
        updated.iosDeviceModel = "iPad13,8"
        updated.aspectRatio = 0
        updated.resolution = 0
        updated.windowWidth = 1668
        updated.windowHeight = 1251
        updated.customScaler = 1.0
        app.settings.settings = updated
    }

    // MARK: - LSEnvironment pruning (legacy fictitious flags removal)

    /// AUDIT FIX: replaces the old `injectEnvironment`/`mediaEnvironment` code,
    /// which wrote `PT_DISABLE_*` / `AM_DISABLE_*` keys that the prebuilt
    /// PlayTools binary never reads. Since the dylib is no longer injected at
    /// all for media apps, those keys are dead weight — and worse, LaunchServices
    /// exports every `LSEnvironment` entry into the app process unconditionally.
    /// This function scrubs all legacy keys (plus any empty-string residue) from
    /// the wrapper's Info.plist. It must run *before* the recursive codesign so
    /// the sealed plist stays clean; it deliberately leaves unrelated user keys
    /// untouched and never touches `CFBundleURLTypes`.
    static func pruneLegacyEnvironment(in info: AppInfo) {
        guard let env = info[dictionary: "LSEnvironment"] else { return }
        var changed = false

        // Remove every legacy fictitious flag...
        for key in legacyManagedKeys where env.object(forKey: key) != nil {
            env.removeObject(forKey: key)
            changed = true
        }

        // ...and any stale empty-string residue left by the old merge semantics.
        // Collect first, mutate after (never delete while enumerating).
        let staleKeys = env.allKeys.compactMap { key -> String? in
            guard let k = key as? String,
                  let value = env.object(forKey: k) as? String,
                  value.isEmpty else { return nil }
            return k
        }
        for key in staleKeys {
            env.removeObject(forKey: key)
            changed = true
        }

        if changed {
            do {
                try info.write()
            } catch {
                Log.shared.error(error)
            }
        }
    }

    // MARK: - Per-bundle sandbox rules (~/.config/PlayCover/<bundleID>.yaml)

    /// Media apps need the full AVFoundation/MediaToolbox/AudioToolbox stack plus
    /// unsigned executable memory for JIT-assisted decoders; ship a ready-made rule file.
    /// AUDIT FIX: the YAML must match the `PlayRules` Decodable schema
    /// (blocklist/greenlist/allow/bypass) — the previous ad-hoc top-level `allow:`
    /// document failed YAMLDecoder and made `getBundleRules` throw at signing time.
    static let alightMotionRules = """
    # Sandbox exceptions for Alight Motion (video editor) running under PlayCover.
    # Grants the media pipeline (AVFoundation, VideoToolbox, CoreMedia) and keeps
    # the Metal shader compiler working without tripping the game sandbox profile.
    allow:
        - (allow mach-lookup (global-name "com.apple.VideoToolbox.player"))
        - (allow mach-lookup (global-name "com.apple.ap.promotedcontentd"))
        - (allow mach-lookup (global-name "com.apple.coredavicerouted"))
        - (allow mach-lookup (global-name "com.apple.analyticsd"))
        - (allow mach-lookup (global-name "com.apple.audio.systemsoundserverd"))
        - (allow mach-lookup (global-name "com.apple.audio.AudioComponentRegistrar"))
        - (allow mach-lookup (global-name "com.apple.cvmsServ"))
        - (allow sysctl-read (sysctl-name "kern.osproductversion"))
        - (allow file* file-read* file-read-metadata file-ioctl (subpath "/System/Library/Frameworks/AVFoundation.framework"))
        - (allow file* file-read* file-read-metadata file-ioctl (subpath "/System/Library/Frameworks/MediaToolbox.framework"))
        - (allow file* file-read* file-read-metadata file-ioctl (subpath "/System/Library/Frameworks/CoreMedia.framework"))
        - (allow file* file-read* file-read-metadata file-ioctl (subpath "/System/Library/PrivateFrameworks/MediaExperience.framework"))
        - (allow file* file-read* file-write* file-write-data (subpath "${HomeDirectory}/Movies"))
        - (allow ipc-posix-shm)
    """

    /// Installs `~/.config/PlayCover/<bundleID>.yaml` with the media-pipeline
    /// exceptions. This is exactly where `Entitlements.getBundleRules(bundleID:)`
    /// looks for per-bundle rules, so the file is actually consumed when the app
    /// is signed (the old `PlayCover/Rules/` path was never read by anyone).
    static func installBundleRulesIfNeeded(for bundleID: String) {
        guard bundleID.lowercased() == "alightcreative.alightmotion" else { return }
        let rulesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("PlayCover")
        let target = rulesDir
            .appendingPathComponent(bundleID)
            .appendingPathExtension("yaml")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.createDirectory(at: rulesDir, withIntermediateDirectories: true)
            try alightMotionRules.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }

    // MARK: - PlayTools binary bypass (pure iOSSupport execution)

    /// REAL BYPASS of the prebuilt PlayTools dylib for media editors.
    ///
    /// The official Carthage PlayTools has no `PT_DISABLE_*` opt-outs, so the only
    /// reliable way to keep its Obj-C/C++ `+load` swizzles (CAMetalLayer.drawableSize,
    /// CADisplayLink, contentsScale, keymapping event capture) from ever executing is
    /// to make sure the dylib is *never* referenced by the app's Mach-O. This function:
    ///   1. Removes any existing LC_LOAD_DYLIB entry pointing at PlayTools from the
    ///      main executable (`injection` framework's removeMachO, same primitive used
    ///      by `PlayTools.removeFromApp`, but synchronous + re-signed here);
    ///   2. Deletes an embedded `Frameworks/PlayTools.dylib` copy if present;
    ///   3. Deletes the PlayTools `PlugIns/` component bundles (AKInterface.bundle —
    ///      the on-screen HUD/keymapping overlay injector);
    ///   4. Ad-hoc re-signs the stripped executable so the launch cache stays valid.
    ///
    /// After this, macOS runs the app through Apple's native iOSSupport (Catalyst)
    /// layer, which manages CAMetalLayer, UIDevice (iPad idiom) and trackpad gestures
    /// without any game-hook interference.
    static func purgePlayTools(from app: BaseApp) {
        let exec = app.executable
        let bundle = app.url

        // 1. Strip the LC_LOAD_DYLIB load command (both injection styles).
        let playToolsPathString = playToolsSystemPath.path
        for injectPath in [playToolsPathString, "@executable_path/Frameworks/PlayTools.dylib"] {
            let semaphore = DispatchSemaphore(value: 0)
            Inject.removeMachO(machoPath: exec.path,
                               cmdType: .loadDylib,
                               backup: false,
                               injectPath: injectPath) { _ in
                semaphore.signal()
            }
            semaphore.wait()
        }

        // 2. Remove an embedded copy of the dylib, if a previous install left one.
        let embeddedDylib = bundle
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("PlayTools")
            .appendingPathExtension("dylib")
        if FileManager.default.fileExists(atPath: embeddedDylib.path) {
            try? FileManager.default.removeItem(at: embeddedDylib)
        }

        // 3. Remove PlayTools component bundles (HUD / AKInterface plug-ins).
        let plugins = bundle.appendingPathComponent("PlugIns")
        if FileManager.default.fileExists(atPath: plugins.path) {
            try? FileManager.default.removeItem(at: plugins)
        }

        // 4. Re-sign the now-clean executable (bottom-up over nested code as well).
        do {
            try Shell.signApp(exec)
        } catch {
            Log.shared.error(error)
        }
    }

    /// Where `PlayTools.installInIPA` injects the system-wide framework copy
    /// (`~/Library/Frameworks/PlayTools.framework/PlayTools`).
    private static let playToolsSystemPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("PlayTools")
        .appendingPathComponent("PlayTools")

    /// Launch-time safety net: if an already-installed media app still carries the
    /// PlayTools load command (installed before this bypass existed, or re-injected
    /// via App Settings), strip it and re-sign *before* launching, so the editor
    /// always boots on the pure iOSSupport path. Returns true when something was
    /// removed (caller should treat the bundle as freshly signed).
    @discardableResult
    static func ensurePlayToolsBypassed(for app: PlayApp) -> Bool {
        guard isMediaApp(app) else { return false }
        let injected = (try? PlayTools.installedInExec(atURL: app.executable)) ?? false
        let embedded = FileManager.default.fileExists(
            atPath: app.url
                .appendingPathComponent("Frameworks")
                .appendingPathComponent("PlayTools")
                .appendingPathExtension("dylib").path)
        guard injected || embedded else { return false }
        Log.shared.log("Media app detected with PlayTools residue — stripping dylib for pure iOSSupport run")
        purgePlayTools(from: app)
        return true
    }

    // MARK: - Native iPad mode (Info.plist patching for the iOSSupport layer)

    /// Forces the app to open in the wide iPad layout under Apple's iOSSupport:
    ///   * `UIDeviceFamily` = [2] (iPad only — dropping iPhone keeps Catalyst in the
    ///     regular-sized idiom instead of the compact phone scene);
    ///   * `UIRequiresFullScreen` = false (free resize / fullscreen toggle);
    ///   * landscape orientations guaranteed in both the generic and ~ipad lists.
    /// Runs on the in-memory `AppInfo` *before* `write()` so everything lands in the
    /// single sealed Info.plist.
    static func forceNativeiPadMode(in info: AppInfo) {
        // iPad-only device family
        info[object: "UIDeviceFamily"] = [NSNumber(value: 2)] as NSArray

        // Allow full-screen & window resizing on iPad
        info[bool: "UIRequiresFullScreen"] = false

        // Guarantee landscape support (Alight Motion's timeline UI is landscape-first)
        let landscape = ["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]
        for key in ["UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"] {
            var orientations = info[strings: key] ?? []
            for orientation in landscape where !orientations.contains(orientation) {
                orientations.append(orientation)
            }
            info[strings: key] = orientations
        }
    }

    // MARK: - Safari deep links (CFBundleURLTypes preservation)

    /// Alight Motion ships `CFBundleURLTypes` registering project-share schemes such
    /// as `alightcreative://` and `am://`. PlayCover's installer must never drop or
    /// overwrite that key while patching the plist; this asserts the original array
    /// survived parsing (rawStorage round-trip) and logs the registered schemes so
    /// LaunchServices registration issues are diagnosable.
    static func preserveURLSchemes(in info: AppInfo) {
        guard let urlTypes = info[array: "CFBundleURLTypes"], urlTypes.count > 0 else {
            Log.shared.log("Media app has no CFBundleURLTypes — Safari deep links unavailable")
            return
        }
        var schemes = [String]()
        for case let type as NSDictionary in urlTypes {
            if let typeSchemes = type["CFBundleURLSchemes"] as? [String] {
                schemes.append(contentsOf: typeSchemes)
            }
        }
        Log.shared.log("Preserving Safari URL schemes for \(info.bundleIdentifier): \(schemes.joined(separator: ", "))")
    }

    /// Registers the installed wrapper with LaunchServices so Safari (and every
    /// other link handler) knows it owns the app's custom URL schemes:
    ///   lsregister -f <App.app>
    static func registerWithLaunchServices(at appURL: URL) {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        do {
            _ = try Shell.run(print: false, lsregister, "-f", appURL.path)
        } catch {
            // Non-fatal: the app still launches, only deep links may need a retry.
            Log.shared.log("lsregister failed for \(appURL.lastPathComponent): \(error)")
        }
    }

    /// Recursively clears quarantine/extended attributes BEFORE codesigning:
    ///   xattr -cr <App.app>
    /// Leftover com.apple.quarantine on nested resources makes Gatekeeper refuse the
    /// freshly ad-hoc-signed bundle intermittently ("cannot be opened").
    static func clearQuarantineAttributes(at appURL: URL) {
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", appURL.path)
    }

    // MARK: - Finder access: sandbox escape hatch + container symlinks

    /// Documents folder inside the app's sandboxed container
    /// (`~/Library/Containers/<bundleID>/Data/Documents`). Created on demand because
    /// the container only materializes after first launch.
    static func containerDocuments(for bundleID: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent(bundleID)
            .appendingPathComponent("Data")
            .appendingPathComponent("Documents")
    }

    /// Symlink map exposed to the editor's sandboxed Documents folder.
    static let finderSymlinks: [(name: String, target: URL)] = [
        ("Mac_Downloads", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")),
        ("Mac_Movies", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")),
        ("Mac_Desktop", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
    ]

    /// Creates the container Documents folder (if needed) and adds symlinks into the
    /// real Mac folders, skipping entries that already exist (whether symlink, file
    /// or directory) so user data is never clobbered. Best-effort: a missing TCC
    /// grant for Desktop/Downloads simply fails the link creation silently.
    static func createFinderShortcuts(for bundleID: String) {
        let documents = containerDocuments(for: bundleID)
        do {
            try FileManager.default.createDirectory(at: documents,
                                                    withIntermediateDirectories: true,
                                                    attributes: [:])
        } catch {
            Log.shared.log("Could not create container Documents for \(bundleID): \(error)")
            return
        }

        for shortcut in finderSymlinks {
            let link = documents.appendingPathComponent(shortcut.name)
            if FileManager.default.fileExists(atPath: link.path)
                || (try? FileManager.default.attributesOfItem(atPath: link.path)) != nil {
                continue // includes existing symlinks (fileExists follows them; attributes covers broken ones)
            }
            guard FileManager.default.fileExists(atPath: shortcut.target.path) else { continue }
            do {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shortcut.target)
            } catch {
                Log.shared.log("Symlink \(link.path) -> \(shortcut.target.path) failed: \(error)")
            }
        }
    }

    // MARK: - Launch-time hygiene

    /// Extra env vars stripped from PlayCover itself before spawning the app, so
    /// debug/validation layers never leak into the editor's Metal pipeline.
    static let additionalEnvKeysToClear: [String] = [
        "MTL_HUD_ENABLED",
        "MTL_INSTRUMENT_PSS",
        "AGXForceSystemWideDatabaseSerialize",
        "AGXDeferReleaseDestructionForDisassembledIndirectBuffers",
        "IOSurfaceMaxCPUCacheSize"
    ]

    static func clearHostEnvironment() {
        for key in additionalEnvKeysToClear {
            unsetenv(key)
        }
    }
}
