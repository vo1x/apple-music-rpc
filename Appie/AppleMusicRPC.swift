import Foundation
import MediaPlayer
import AppKit




class AppleMusicDiscordRPC {
    private let discordRPC: DiscordRPC
    private var timer: Timer?
    private var lastTrackIdentifier: String = ""
    
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
        updateDiscordPresence()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateDiscordPresence()
        }
    }
    
    internal func updateDiscordPresence() {
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let trackInfo = self.getAppleMusicTrackInfo() else {
                DispatchQueue.main.async {
                    self.discordRPC.clearPresence()
                    self.lastTrackIdentifier = ""
                    print("No music playing or AppleScript failed to get track info, cleared Discord presence.")
                }
                return
            }
            
            
            print("DEBUG: TrackInfo from AppleScript - Title: '\(trackInfo.title)', Artist: '\(trackInfo.artist)', Duration: \(trackInfo.duration)s, Position: \(trackInfo.position)s, IsPlaying: \(trackInfo.isPlaying)")


            let currentTrackIdentifier = "\(trackInfo.title)-\(trackInfo.artist)-\(trackInfo.album)-\(trackInfo.isPlaying)-\(trackInfo.position)"
            
            guard currentTrackIdentifier != self.lastTrackIdentifier else {
                
                return
            }
            
            print("Now Playing: \(trackInfo.title) by \(trackInfo.artist) (Updating Discord)")
            
            let startTimestamp: Date?
            let endTimestamp: Date?
            
            if trackInfo.isPlaying {
                startTimestamp = Date().addingTimeInterval(-(trackInfo.position))
                endTimestamp = Date().addingTimeInterval(trackInfo.duration - trackInfo.position)
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
                    startTimestamp: startTimestamp,
                    endTimestamp: endTimestamp ,
                    type: 2, // This changes the status type from Playing to Listenin to
                )
                
                self.lastTrackIdentifier = currentTrackIdentifier
            }
        }
    }
    
    private func clearPresence() {
        discordRPC.clearPresence()
        lastTrackIdentifier = ""
    }

    private struct AppleScriptTrackInfo {
        let title: String
        let artist: String
        let album: String
        let isPlaying: Bool
        let duration: Double
        let position: Double
        let artwork: NSImage?
    }

    private func getAppleMusicTrackInfo() -> AppleScriptTrackInfo? {
        let appleScript = """
        tell application "Music"
            if it is running then
                if player state is playing then
                    set currentTrack to current track
                    set trackName to name of currentTrack
                    set artistName to artist of currentTrack
                    set albumName to album of currentTrack
                    set trackDuration to duration of currentTrack
                    set playerPosition to player position
                    return trackName & "||" & artistName & "||" & albumName & "||" & trackDuration & "||" & playerPosition & "||" & "playing"
                else if player state is paused then
                    set currentTrack to current track
                    set trackName to name of currentTrack
                    set artistName to artist of currentTrack
                    set albumName to album of currentTrack
                    set trackDuration to duration of currentTrack
                    set playerPosition to player position
                    return trackName & "||" & artistName & "||" & albumName & "||" & trackDuration & "||" & playerPosition & "||" & "paused"
                end if
            end if
        end tell
        return "NOT_PLAYING"
        """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: appleScript) else {
            print("AppleScript compilation error.")
            return nil
        }
        
        let output = scriptObject.executeAndReturnError(&error)
        
        if let error = error {
            let errorNumber = error["NSAppleScriptErrorNumber"] as? Int ?? 0
            if errorNumber == -1743 { // -1743 is "Automation access denied"
                print("AppleScript permission error: User needs to grant automation access for 'Music'.")
                DispatchQueue.main.async { [weak self] in
                    self?.onPermissionError?("This app needs permission to control Apple Music. Please go to System Settings > Privacy & Security > Automation, find '\(Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Your App")' and enable the checkbox next to 'Music'.")
                }
            } else {
                print("AppleScript execution error: \(error)")
            }
            return nil
        }
        
        let result = output.stringValue ?? ""
        
        if result == "NOT_PLAYING" { return nil }

        let parts = result.components(separatedBy: "||")
        if parts.count == 6 {
            let title = parts[0]
            let artist = parts[1]
            let album = parts[2]
            let duration = Double(parts[3]) ?? 0
            let position = Double(parts[4]) ?? 0
            let isPlayingString = parts[5]
            let isPlaying = (isPlayingString == "playing")
            
            
            let artwork = getAppleMusicArtwork()
            
            return AppleScriptTrackInfo(title: title, artist: artist, album: album, isPlaying: isPlaying, duration: duration, position: position, artwork: artwork)
        }
        print("AppleScript returned unexpected format for track info: \(result)")
        return nil
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
