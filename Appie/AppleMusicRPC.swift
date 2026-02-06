import Foundation
import MediaPlayer
import AppKit
import ScriptingBridge


class AppleMusicDiscordRPC {
    private let discordRPC: DiscordRPC
    private var timer: Timer?
    private var positionTimer: Timer?
    private var lastTrackIdentifier: String = ""
    private var lastNotificationAt: Date?
    private var lastSuccessfulFetchAt: Date?
    private var consecutivePollFailures: Int = 0
    private var lastPositionSeconds: Double = 0
    private var lastIsPlaying: Bool = false
    private var lastPositionUpdateAt: Date?
    private var lastTrackBaseId: String = ""
    private var notificationObservers: [NSObjectProtocol] = []
    
    var onPermissionError: ((String) -> Void)?
    
    init(discordAppId: String) {
        self.discordRPC = DiscordRPC(appId: discordAppId)
        
        self.discordRPC.onConnect = { [weak self] in
            print("AppleMusicDiscordRPC: Connected to Discord!")
            self?.updateDiscordPresence()
        }
        self.discordRPC.onDisconnect = { [weak self] in
            print("AppleMusicDiscordRPC: Discord disconnected.")
            self?.clearPresence()
        }
    }
    
    func start() {
        discordRPC.connect()
        startMusicMonitoring()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        positionTimer?.invalidate()
        positionTimer = nil
        removeMusicObservers()
        discordRPC.disconnect()
    }
    
    func reconnectDiscord() {
        discordRPC.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.discordRPC.connect()
        }
    }
    
    func clearDiscordPresence() {
        discordRPC.clearPresence()
    }

    func triggerPresenceUpdate() {
        print("Manually triggered presence update in AppleMusicDiscordRPC.")
        updateDiscordPresence()
    }

    private func startMusicMonitoring() {
        startMusicObservers()
        updateDiscordPresence()
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let lastNotificationAt = self.lastNotificationAt,
               Date().timeIntervalSince(lastNotificationAt) < 20 {
                if self.lastIsPlaying,
                   let lastPositionUpdateAt = self.lastPositionUpdateAt,
                   Date().timeIntervalSince(lastPositionUpdateAt) < 10 {
                    return
                }
            }
            self.updateDiscordPresence()
        }

        positionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.lastIsPlaying {
                self.updateDiscordPresence()
            }
        }
    }
    
    internal func updateDiscordPresence() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            print("DEBUG: updateDiscordPresence() called")
            let trackInfo = self.getAppleMusicTrackInfo()
            self.applyTrackInfo(trackInfo, source: "poll", forceUpdate: true)
        }
    }
    
    private func clearPresence() {
        discordRPC.clearPresence()
        lastTrackIdentifier = ""
    }

    private struct TrackInfo {
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let duration: Double
        let position: Double
    }

    private func getAppleMusicTrackInfo() -> TrackInfo? {
        guard let app = SBApplication(bundleIdentifier: "com.apple.Music") else {
            print("DEBUG: SBApplication(bundleIdentifier:) returned nil")
            return nil
        }
        if app.isRunning == false {
            print("DEBUG: Music app not running per ScriptingBridge")
            return nil
        }

        let rawState = sbValue(app, key: "playerState")
        let state = parsePlayerState(rawState)
        if state == "stopped" {
            print("DEBUG: ScriptingBridge state=stopped raw=\(stringify(rawState))")
            return nil
        }

        guard let track = sbValue(app, key: "currentTrack") as? NSObject else {
            print("DEBUG: ScriptingBridge currentTrack is nil")
            return nil
        }

        let title = (sbValue(track, key: "name") as? String) ?? ""
        if title.isEmpty {
            print("DEBUG: ScriptingBridge track name is empty")
            return nil
        }

        let artist = (sbValue(track, key: "artist") as? String) ?? ""
        let album = (sbValue(track, key: "album") as? String) ?? ""
        let rawDuration = sbValue(track, key: "duration")
        let rawPosition = sbValue(app, key: "playerPosition")
        let duration = parseDouble(rawDuration)
        let position = parseDouble(rawPosition)
        let isPlaying = (state == "playing")

        print("DEBUG: scripting bridge state=\(state) position=\(position) rawState=\(stringify(rawState)) rawPosition=\(stringify(rawPosition))")

        return TrackInfo(
            title: title,
            artist: artist,
            album: album,
            isPlaying: isPlaying,
            duration: duration,
            position: position
        )
    }

    private func sbValue(_ object: NSObject, key: String) -> Any? {
        return object.value(forKey: key)
    }

    private func parsePlayerState(_ raw: Any?) -> String {
        if let state = raw as? String { return state }
        if let state = raw as? NSNumber {
            let code = state.uint32Value
            let fourcc = fourCCString(code)
            switch fourcc {
            case "kPSP": return "playing"
            case "kPSp": return "paused"
            case "kPSS": return "stopped"
            default:
                switch state.intValue {
                case 0: return "stopped"
                case 1: return "playing"
                case 2: return "paused"
                default: return "stopped"
                }
            }
        }
        if let obj = raw as? NSObject,
           let name = obj.value(forKey: "name") as? String {
            return name
        }
        return "stopped"
    }

    private func parseDouble(_ raw: Any?) -> Double {
        if let v = raw as? Double { return v }
        if let v = raw as? NSNumber { return v.doubleValue }
        if let v = raw as? NSAppleEventDescriptor { return v.doubleValue }
        return 0
    }

    private func fourCCString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func stringify(_ value: Any?) -> String {
        guard let value = value else { return "nil" }
        if let num = value as? NSNumber {
            return "\(type(of: value)):\(value) fourcc=\(fourCCString(num.uint32Value))"
        }
        return "\(type(of: value)):\(value)"
    }

    private func startMusicObservers() {
        let center = DistributedNotificationCenter.default()
        let names = [
            Notification.Name("com.apple.iTunes.playerInfo"),
            Notification.Name("com.apple.Music.playerInfo")
        ]

        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.handlePlayerInfoNotification(notification)
            }
            notificationObservers.append(observer)
        }
    }

    private func removeMusicObservers() {
        let center = DistributedNotificationCenter.default()
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    private func handlePlayerInfoNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        print("DEBUG: playerInfo keys: \(Array(userInfo.keys))")

        let state = (userInfo["Player State"] as? String) ?? ""
        if state == "Stopped" {
            clearPresence()
            return
        }

        let title = (userInfo["Name"] as? String) ?? ""
        let artist = (userInfo["Artist"] as? String) ?? ""
        let album = (userInfo["Album"] as? String) ?? ""

        if title.isEmpty {
            updateDiscordPresence()
            return
        }

        print("DEBUG: notification state=\(state)")
        lastNotificationAt = Date()
        updateDiscordPresence()
    }

    private func applyTrackInfo(_ trackInfo: TrackInfo?, source: String, forceUpdate: Bool) {
        if trackInfo == nil, source == "poll" {
            consecutivePollFailures += 1
            if let lastNotificationAt = lastNotificationAt,
               Date().timeIntervalSince(lastNotificationAt) < 60 {
                return
            }
            if let lastSuccessfulFetchAt = lastSuccessfulFetchAt,
               Date().timeIntervalSince(lastSuccessfulFetchAt) < 60,
               consecutivePollFailures < 3 {
                return
            }
        }
        guard let trackInfo = trackInfo else {
            DispatchQueue.main.async {
                self.discordRPC.clearPresence()
                self.lastTrackIdentifier = ""
                print("No music playing or fetch failed (\(source)), cleared Discord presence.")
            }
            return
        }

        consecutivePollFailures = 0
        lastSuccessfulFetchAt = Date()
        lastIsPlaying = trackInfo.isPlaying

        print("DEBUG: TrackInfo (\(source)) - Title: '\(trackInfo.title)', Artist: '\(trackInfo.artist)', Duration: \(trackInfo.duration)s, Position: \(trackInfo.position)s, IsPlaying: \(trackInfo.isPlaying)")

        let baseTrackId = "\(trackInfo.title)-\(trackInfo.artist)-\(trackInfo.album)"
        let currentTrackIdentifier = "\(baseTrackId)-\(trackInfo.isPlaying)"
        let positionDelta = abs(trackInfo.position - lastPositionSeconds)
        let shouldUpdateForPosition = trackInfo.isPlaying && positionDelta >= 5
        guard currentTrackIdentifier != lastTrackIdentifier || forceUpdate || shouldUpdateForPosition else { return }

        print("Now Playing: \(trackInfo.title) by \(trackInfo.artist) (Updating Discord)")

        let startTimestamp: Date?
        let endTimestamp: Date?

        var effectivePosition = trackInfo.position
        if trackInfo.isPlaying,
           !lastIsPlaying,
           effectivePosition <= 0.1,
           baseTrackId == lastTrackBaseId,
           lastPositionSeconds > 0 {
            effectivePosition = lastPositionSeconds
        }

        if trackInfo.isPlaying {
            startTimestamp = Date().addingTimeInterval(-(effectivePosition))
            endTimestamp = Date().addingTimeInterval(trackInfo.duration - effectivePosition)
        } else {
            startTimestamp = nil
            endTimestamp = nil
        }

        DispatchQueue.main.async {
            self.discordRPC.setPresence(
                details: trackInfo.title,
                state: "\(trackInfo.artist)",
                largeImageKey: "apple_music",
                largeImageText: trackInfo.album,
                smallImageKey: trackInfo.isPlaying ? nil : "pause",
                smallImageText: trackInfo.isPlaying ? nil : "Paused",
                startTimestamp: startTimestamp,
                endTimestamp: endTimestamp,
                type: 2,
                clearTimestamps: false
            )
            self.lastTrackIdentifier = currentTrackIdentifier
            self.lastPositionSeconds = effectivePosition
            self.lastPositionUpdateAt = Date()
            self.lastTrackBaseId = baseTrackId
        }
    }

    
// It fetches the artwork but discord seems to be having issues with the buffer thats being sent
    private func getAppleMusicArtwork() -> NSImage? {
        
        let artworkScript = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    set currentTrack to current track
                    try
                        set artworkList to artworks of currentTrack
                        if (count of artworkList) > 0 then
                            -- Get artwork data of the first artwork as PNG bytes
                            set theData to data of artwork 1 of currentTrack as «class PNG »
                            
                            -- Convert the PNG data to a base64 string using shell script
                            -- 'text of theData' converts the raw data to a string for echo
                            set base64String to do shell script "echo " & quoted form of (theData as string) & " | base64"
                            return base64String
                        else
                            return "NO_ARTWORK"
                        end if
                    on error errorMessage
                        return "ERROR: " & errorMessage
                    end try
                else
                    return "NOT_PLAYING"
                end if
            end if
        end tell
        return "" -- Return empty string if Music isn't running or nothing is playing
        """
        
        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: artworkScript) else {
            print("Artwork AppleScript compilation error: Invalid script syntax.")
            return nil
        }
        
        let output = scriptObject.executeAndReturnError(&error)
        
        if let error = error {
            print("Artwork AppleScript execution error: \(error)")
            return nil
        }
        
        let result = output.stringValue ?? ""
        
        if result == "NO_ARTWORK" {
            print("Track has no artwork.")
            return nil
        } else if result.hasPrefix("ERROR:") {
            print("AppleScript reported an error retrieving artwork: \(result)")
            return nil
        } else if result == "NOT_PLAYING" || result.isEmpty {
            // print("Music not playing or script returned empty for artwork.")
            return nil
        } else {
            guard let imageData = Data(base64Encoded: result, options: .ignoreUnknownCharacters) else {
                print("Failed to decode base64 artwork data. Result length: \(result.count) (starts with: \(result.prefix(50)))...")
                return nil
            }
            
            
            guard let image = NSImage(data: imageData) else {
                print("Failed to create NSImage from data. Data size: \(imageData.count) bytes.")
                return nil
            }
            
            print("Successfully retrieved and decoded artwork (size: \(imageData.count) bytes).")
            return image
        }
    }
}
