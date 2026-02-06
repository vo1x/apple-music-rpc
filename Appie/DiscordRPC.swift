

import Foundation
import Darwin
import AppKit

class DiscordRPC {
    private let appId: String
    private var socketFD: Int32 = -1
    private let queue = DispatchQueue(label: "discord.rpc")
    private var isConnected = false
    private var readerTask: Task<Void, Never>?
    
    
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    
    init(appId: String) {
        self.appId = appId
    }
    
    func connect() {
        for i in 0..<10 {
            
            let path = (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/") + "discord-ipc-\(i)"
            

            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                print("Failed to create socket: \(String(cString: strerror(errno)))")
                continue
            }

            
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                let pathBytes = path.utf8CString.dropLast()
                let bytesToCopy = min(pathBytes.count, ptr.count - 1)
                ptr.copyBytes(from: pathBytes.prefix(bytesToCopy).map { UInt8(bitPattern: $0) })
            }
            
            let len = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            
            let res = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, len)
                }
            }
            
            if res == 0 {
                
                socketFD = fd
                isConnected = true
                print("Connected to Discord IPC at \(path)")
                
                
                readerTask = Task { [weak self] in
                    await self?.reader()
                }
                
                
                handshake()
                return
            } else {
                
                Darwin.close(fd)
            }
        }
        
        print("Could not connect to Discord. Make sure Discord is running and try again.")
    }
    
    
    func disconnect() {
        if socketFD >= 0 {
            
            Darwin.close(socketFD)
            socketFD = -1
        }
        isConnected = false
        readerTask?.cancel()
        readerTask = nil
        onDisconnect?()
        print("🔌 Disconnected from Discord.")
    }
    
    
    private func handshake() {
        let handshake: [String: Any] = [
            "v": 1,
            "client_id": appId
        ]
        sendMessage(opcode: 0, data: handshake)
    }
    
    func setPresence(details: String? = nil,
                    state: String? = nil,
                    largeImageKey: String? = nil,
                    largeImageText: String? = nil,
                    smallImageKey: String? = nil,
                    smallImageText: String? = nil,
                    startTimestamp: Date? = nil,
                     endTimestamp: Date?=nil,
                     type: Int? = nil,
                     clearTimestamps: Bool = false) {
        
        guard isConnected else {
            print("Not connected to Discord, cannot set presence.")
            return
        }
        
        var activity: [String: Any] = [:]
        
        if let type = type {
            activity["type"]=type
        }
        
        if let details = details {
            activity["details"] = details
        }
        
        if let state = state {
            activity["state"] = state
        }
        
        
        if largeImageKey != nil || largeImageText != nil || smallImageKey != nil || smallImageText != nil {
            var assets: [String: Any] = [:]
            if let key = largeImageKey {
                assets["large_image"] = key
            }
            if let text = largeImageText {
                assets["large_text"] = text
            }
            if let key = smallImageKey {
                assets["small_image"] = key
            }
            if let text = smallImageText {
                assets["small_text"] = text
            }
            activity["assets"] = assets
        }
        
        
             if !clearTimestamps && (startTimestamp != nil || endTimestamp != nil) {
                 var timestamps: [String: Any] = [:]
                 if let start = startTimestamp {
                     timestamps["start"] = Int(start.timeIntervalSince1970)
                 }
                 if let end = endTimestamp {
                     timestamps["end"] = Int(end.timeIntervalSince1970)
                 }
                 activity["timestamps"] = timestamps
             }
        
        
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "activity": activity
            ],
            "nonce": UUID().uuidString
        ]
        
        
        sendMessage(opcode: 1, data: payload)
    }
    
    
    func clearPresence() {
        guard isConnected else { return }
        
        
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": ProcessInfo.processInfo.processIdentifier
            ],
            "nonce": UUID().uuidString
        ]
        
        sendMessage(opcode: 1, data: payload)
        print("Cleared Discord presence.")
    }
    
    
    private func sendMessage(opcode: UInt32, data: [String: Any], completion: (() -> Void)? = nil) {
        guard socketFD >= 0 else { return }
        
        do {
            // Serialize JSON payload
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let length = UInt32(jsonData.count)
            
            // Discord RPC frame format: [opcode: 4 bytes][length: 4 bytes][json data]
            var frame = Data()
            frame.append(contentsOf: withUnsafeBytes(of: opcode.littleEndian) { Data($0) })
            frame.append(contentsOf: withUnsafeBytes(of: length.littleEndian) { Data($0) })
            frame.append(jsonData)
            
            
            let result = frame.withUnsafeBytes { bytes in
                Darwin.write(socketFD, bytes.baseAddress, frame.count)
            }
            
            if result == frame.count {
                completion?()
            } else {
                print("Write error: sent \(result) of \(frame.count) bytes. Error: \(String(cString: strerror(errno)))")
            }
        } catch {
            print("JSON serialization error: \(error)")
        }
    }
    
    
    private func reader() async {
        while socketFD >= 0 && isConnected {
            
            var header = Data(count: 8)
            let headerResult = header.withUnsafeMutableBytes { bytes in
                Darwin.read(socketFD, bytes.baseAddress, 8)
            }
            
            guard headerResult == 8 else {
                if headerResult == 0 {
                    
                    print("Discord disconnected (socket closed by peer).")
                    Task { @MainActor [weak self] in
                        self?.disconnect()
                    }
                } else if headerResult < 0 {
                    
                    print("Read error from socket header: \(String(cString: strerror(errno)))")
                    Task { @MainActor [weak self] in
                        self?.disconnect()
                    }
                }
                break
            }
            
            
            let opcode = header.withUnsafeBytes { $0.load(as: UInt32.self) }
            let length = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            
            
            var payload = Data(count: Int(length))
            let payloadResult = payload.withUnsafeMutableBytes { bytes in
                Darwin.read(socketFD, bytes.baseAddress, Int(length))
            }
            
            guard payloadResult == Int(length) else {
                if payloadResult < 0 {
                    print("Payload read error: \(String(cString: strerror(errno)))")
                }
                break
            }
            
            
            if opcode == 1 {
                do {
                    if let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                        if json["evt"] as? String == "READY" {
                            
                            Task { @MainActor [weak self] in
                                self?.onConnect?()
                            }
                        } else if json["evt"] as? String == "ERROR" {
                            
                            print("Discord RPC Error: \(json)")
                        } else {
                            
                            // print("Received Discord event: \(json)")
                        }
                    }
                } catch {
                    print("JSON parse error from Discord payload: \(error)")
                }
            }
        }
    }
}
