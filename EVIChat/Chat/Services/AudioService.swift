//
//  AudioService.swift
//  Swift-EVIChat
//
//  Created by Andreas Naoum on 06/02/2025.
//

import Foundation
import AVFoundation

enum AudioServiceError: LocalizedError {
    case engineStartFailed
    case invalidData
    case bufferCreationFailed
    case playbackFailed
    
    var errorDescription: String? {
        switch self {
        case .engineStartFailed:
            return "Failed to start audio engine"
        case .invalidData:
            return "Invalid audio data received"
        case .bufferCreationFailed:
            return "Failed to create audio buffer"
        case .playbackFailed:
            return "Failed to play audio"
        }
    }
}

final class AudioService: NSObject, AudioServiceProtocol, AVAudioPlayerDelegate {
    // MARK: - Properties
    weak var delegate: AudioServiceDelegate?
    private(set) var isRunning = false
    var isMuted = false
    
    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private let audioSession = AVAudioSession.sharedInstance()
    
    // Audio playback properties
    private var audioPlaybackQueue: [URL] = []
    private var isAudioPlaying = false
    private var currentAudioPlayer: AVAudioPlayer?
    
    // Audio format configuration
    private var nativeInputFormat: AVAudioFormat?
    private let eviAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 48000,
        channels: 1,
        interleaved: true
    )!
    
    private let bufferSizeFrames: AVAudioFrameCount = 4800 // 100ms at 48kHz
    
    // MARK: - Initialization
    override init() {
        self.inputNode = audioEngine.inputNode
        
        super.init()
        
        // Don't do any audio setup in init() to avoid deadlocks during app initialization
        // All audio setup will be deferred until start() is called
    }
    
    // MARK: - Public Methods
    func start() throws {
        guard !isRunning else { return }
        
        // Ensure we're on the main thread for all audio operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                try? self?.start()
            }
            return
        }
        
        // Setup audio session first (only when actually needed)
        setupAudioSession()
        
        // Small async delay to let session stabilize before setting up engine
        // This avoids RPC timeouts and deadlocks
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, !self.isRunning else { return }
            
            do {
                // Setup audio engine now - ensure session is active and format is valid
                // If setup fails (e.g., simulator), we'll skip engine start but not crash
                let setupSuccess = self.setupAudioEngine()
                
                guard setupSuccess else {
                    print("⚠️ Audio engine setup incomplete - continuing without audio capture")
                    // Don't throw error - allow app to continue
                    self.isRunning = true
                    return
                }
                
                print("🎧 Starting audio engine...")
                try self.audioEngine.start()
                print("✅ Audio engine started")
                print("🎤 Starting recording...")
                self.startRecording()
                print("✅ Recording started")
                self.isRunning = true
            } catch {
                print("❌ Failed to start audio engine: \(error)")
                // If we're on simulator or audio isn't available, don't crash - just log
                print("⚠️ Continuing without audio capture")
                self.isRunning = true
                // Don't throw - allow app to continue
            }
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.disconnectNodeInput(inputNode)
        handleInterruption()
        isRunning = false
    }
    
    func handleInterruption() {
        // Stop current playback
        currentAudioPlayer?.stop()
        currentAudioPlayer = nil
        
        // Clean up queue
        for fileURL in audioPlaybackQueue {
            cleanupFile(at: fileURL)
        }
        audioPlaybackQueue.removeAll()
        
        // Reset state
        isAudioPlaying = false
    }
    
    func playAudio(_ base64Data: String) {
        // Decode base64 audio data
        guard let audioData = Data(base64Encoded: base64Data) else {
            delegate?.audioService(self, didEncounterError: AudioServiceError.invalidData)
            return
        }
        
        // Create a temporary file URL
        let temporaryFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        
        do {
            // Write audio data to temporary file
            try audioData.write(to: temporaryFileURL)
            
            // Add to audio playback queue
            audioPlaybackQueue.append(temporaryFileURL)
            
            // Start playback if not already playing
            processAudioPlaybackQueue()
        } catch {
            delegate?.audioService(self, didEncounterError: error)
        }
    }
    
    private func setupAudioEngine() -> Bool {
        // All audio engine operations MUST happen on the main thread
        guard Thread.isMainThread else {
            print("❌ setupAudioEngine() must be called on main thread")
            return false
        }
        
        print("🎛️ Setting up audio engine...")
        
        // Ensure audio session is active (already set up in start(), but verify)
        do {
            try audioSession.setActive(true)
        } catch {
            print("⚠️ Failed to activate audio session: \(error)")
            return false
        }
        
        // Re-capture input format after session is active
        let inputFormat = inputNode.inputFormat(forBus: 0)
        self.nativeInputFormat = inputFormat
        
        let mainMixer = audioEngine.mainMixerNode
        print("   - Main mixer format: \(mainMixer.outputFormat(forBus: 0))")
        print("   - Input format: \(inputFormat)")
        
        // Validate format before connecting
        guard inputFormat.channelCount > 0 && inputFormat.sampleRate > 0 else {
            print("❌ No valid input format available (channels: \(inputFormat.channelCount), sampleRate: \(inputFormat.sampleRate))")
            print("   This might be a simulator issue - audio input may not be available")
            return false
        }
        
        // Disconnect if already connected (idempotent)
        audioEngine.disconnectNodeInput(inputNode)
        
        // Connect input to mixer
        print("   - Connecting input with format: \(inputFormat)")
        audioEngine.connect(inputNode, to: mainMixer, format: inputFormat)
        print("✅ Input connected to mixer")
        
        audioEngine.prepare()
        print("✅ Audio engine prepared")
        return true
    }
    
    private func setupAudioSessionOld() {
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            delegate?.audioService(self, didEncounterError: error)
        }
    }
    
    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,  // Using voiceChat for echo cancellation
                options: [
                    .mixWithOthers,
//                    .defaultToSpeaker,  // This helps with speech recognition
//                    .allowBluetooth
                ]
            )
            
            try audioSession.setPreferredSampleRate(48000)
            try audioSession.setPreferredInputNumberOfChannels(1)
            
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            print("✅ Audio Session Setup Successful")
            print("Actual sample rate: \(audioSession.sampleRate)")
            print("Actual IO buffer duration: \(audioSession.ioBufferDuration)")
            print("Input number of channels: \(audioSession.inputNumberOfChannels)")
        } catch {
            print("🚨 Audio Session Setup Failed: \(error)")
        }
    }
    
    private func startRecording() {
            print("🎤 Starting audio recording setup...")
            inputNode.removeTap(onBus: 0)
            
            if let inputFormat = nativeInputFormat {
                print("📊 Input format detected:")
                print("   - Sample rate: \(inputFormat.sampleRate)")
                print("   - Channels: \(inputFormat.channelCount)")
                print("   - Format flags: \(inputFormat.commonFormat.rawValue)")
                
                inputNode.installTap(
                    onBus: 0,
                    bufferSize: bufferSizeFrames,
                    format: inputFormat
                ) { [weak self] buffer, _ in
                    print("🎙️ Received audio buffer with \(buffer.frameLength) frames")
                    self?.processAudioBuffer(buffer)
                }
                print("✅ Audio tap installed successfully")
            } else {
                
                print("❌ Failed to get native input format")
            }
        }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else { return }
        
        // Create a new buffer with the target format (Int16)
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: eviAudioFormat,
            frameCapacity: buffer.frameLength
        ) else {
            delegate?.audioService(self, didEncounterError: AudioServiceError.bufferCreationFailed)
            return
        }
        
        let floatData = buffer.floatChannelData?[0]
        let int16Data = convertedBuffer.int16ChannelData?[0]
        let frameLength = Int(buffer.frameLength)
        
        for frame in 0..<frameLength {
            let floatSample = floatData?[frame] ?? 0
            let scaledSample = max(-1.0, min(floatSample, 1.0)) * 32767.0
            int16Data?[frame] = Int16(scaledSample)
        }
        
        convertedBuffer.frameLength = buffer.frameLength
        
        guard let channelData = convertedBuffer.int16ChannelData?[0] else { return }
        
        let byteCount = Int(convertedBuffer.frameLength * 2)
        let audioData = Data(bytes: channelData, count: byteCount)
        
        delegate?.audioService(self, didCaptureAudio: audioData.base64EncodedString())
    }
    
    private func processAudioPlaybackQueue() {
        guard !isAudioPlaying, !audioPlaybackQueue.isEmpty else { return }
        
        let fileToPlay = audioPlaybackQueue.removeFirst()
        
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: fileToPlay)
            audioPlayer.delegate = self
            
            isAudioPlaying = true
            
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            
            currentAudioPlayer = audioPlayer
        } catch {
            cleanupFile(at: fileToPlay)
            delegate?.audioService(self, didEncounterError: error)
            
            isAudioPlaying = false
            processAudioPlaybackQueue()
        }
    }
    
    private func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if let currentURL = currentAudioPlayer?.url {
            cleanupFile(at: currentURL)
        }
        
        currentAudioPlayer = nil
        isAudioPlaying = false
        
        DispatchQueue.main.async { [weak self] in
            self?.processAudioPlaybackQueue()
        }
    }
    
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error = error {
            delegate?.audioService(self, didEncounterError: error)
        }
        
        if let currentURL = currentAudioPlayer?.url {
            cleanupFile(at: currentURL)
        }
        
        currentAudioPlayer = nil
        isAudioPlaying = false
        
        DispatchQueue.main.async { [weak self] in
            self?.processAudioPlaybackQueue()
        }
    }
}

