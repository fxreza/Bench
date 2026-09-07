import Foundation

/// Playback *control* through MediaRemote, in-process.
///
/// Reading now-playing information is gated behind an entitlement since macOS
/// 15.4 (hence the perl adapter), but `MRMediaRemoteSendCommand` and
/// `MRMediaRemoteSetElapsedTime` were never gated. Verified on macOS 26.6.2
/// from an ad-hoc signed .app bundle: both reach the now-playing app, so Piko
/// avoids a perl spawn per button press.
enum MediaRemoteBridge {
    /// MRCommand ids, matching the adapter's `send COMMAND` table.
    enum Command: Int {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case stop = 3
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Bool
    private typealias SetElapsedTimeFn = @convention(c) (Double) -> Void

    private struct Functions {
        var send: SendCommandFn
        var setElapsedTime: SetElapsedTimeFn?
    }

    private static let functions: Functions? = {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL) else {
            Log.media.error("MediaRemote.framework not found; falling back to the adapter script")
            return nil
        }
        guard let sendPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteSendCommand" as CFString)
        else {
            Log.media.error("MRMediaRemoteSendCommand unavailable; falling back to the adapter script")
            return nil
        }
        let elapsedPtr = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteSetElapsedTime" as CFString)
        return Functions(
            send: unsafeBitCast(sendPtr, to: SendCommandFn.self),
            setElapsedTime: elapsedPtr.map { unsafeBitCast($0, to: SetElapsedTimeFn.self) })
    }()

    /// True when the in-process symbols resolved. False means every command
    /// goes through `perl mediaremote-adapter.pl ... send N`.
    static var isAvailable: Bool { functions != nil }

    static func send(_ command: Command) {
        guard let functions else {
            MediaRemoteAdapter.runDetached(["send", String(command.rawValue)])
            return
        }
        let ok = functions.send(command.rawValue, nil)
        if !ok {
            Log.media.error("MRMediaRemoteSendCommand(\(command.rawValue)) returned false")
        }
    }

    /// Absolute seek, in seconds.
    static func setElapsedTime(_ seconds: TimeInterval) {
        guard let setElapsedTime = functions?.setElapsedTime else {
            // The script takes microseconds and rejects negative values.
            let micros = Int(max(0, seconds) * 1_000_000)
            MediaRemoteAdapter.runDetached(["seek", String(micros)])
            return
        }
        setElapsedTime(max(0, seconds))
    }
}
