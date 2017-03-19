 //
//  AudioModule.swift
//  minimalTunes
//
//  Created by John Moody on 6/13/16.
//  Copyright © 2016 John Moody. All rights reserved.
//

import Cocoa
import AVFoundation

// FIXME: comparison operators with optionals were removed from the Swift Standard Libary.
// Consider refactoring the code to use the non-optional operators.
fileprivate func < <T : Comparable>(lhs: T?, rhs: T?) -> Bool {
    switch (lhs, rhs) {
    case let (l?, r?):
        return l < r
    case (nil, _?):
        return true
    default:
        return false
    }
}


enum completionHandlerType {
    case seek
    case natural
    case destroy
}
 
//typealias FLAC__StreamDecoderReadCallback = (Optional<UnsafePointer<FLAC__StreamDecoder>>, Optional<UnsafeMutablePointer<UInt8>>, Optional<UnsafeMutablePointer<Int>>, Optional<UnsafeMutableRawPointer>) -> FLAC__StreamDecoderReadStatus
 

class AudioModule: NSObject {
    /*
  
    graph structure:
  
    player node
        |
    equalizer
        |
    mainMixerNode (for volume control)
        |
    outputNode
  
    */
    
    //todo consistent naming
    dynamic var trackQueue = [Track]()
    dynamic var currentTrackLocation: String?
    var networkFlag = false
    var fileBuffererDictionary = [URL : FileBufferer]()
    var currentFileBufferer: FileBufferer?
    
    let verbotenFileTypes = ["m4v", "m4p"]
    
    var curPlayerNode = AVAudioPlayerNode()
    var equalizer: AVAudioUnitEQ = {
        let doingle = AVAudioUnitEQ(numberOfBands: 10)
        let bands = doingle.bands
        bands[0].frequency = 32
        bands[0].bandwidth = 1
        bands[0].bypass = false
        bands[1].frequency = 64
        bands[1].bandwidth = 1
        bands[1].bypass = false
        bands[2].frequency = 128
        bands[2].bandwidth = 1
        bands[2].bypass = false
        bands[3].frequency = 256
        bands[3].bandwidth = 1
        bands[3].bypass = false
        bands[4].frequency = 512
        bands[4].bandwidth = 1
        bands[4].bypass = false
        bands[5].frequency = 1024
        bands[5].bandwidth = 1
        bands[5].bypass = false
        bands[6].frequency = 2048
        bands[6].bandwidth = 1
        bands[6].bypass = false
        bands[7].frequency = 4096
        bands[7].bandwidth = 1
        bands[7].bypass = false
        bands[8].frequency = 8192
        bands[8].bandwidth = 1
        bands[8].bypass = false
        bands[9].frequency = 16384
        bands[9].bandwidth = 1
        bands[9].bypass = false
        if let defaultsEQ = UserDefaults.standard.object(forKey: DEFAULTS_CURRENT_EQ_STRING) as? [Float] {
            var index = 0
            for band in defaultsEQ {
                if index == 10 {continue}
                bands[index].gain = band
                index += 1
            }
            doingle.globalGain = defaultsEQ[10]
        }
        return doingle
    }()
    var curFile: AVAudioFile?
    var audioEngine = AVAudioEngine()
    
    dynamic var is_initialized = false
    dynamic var track_changed = false
    dynamic var needs_tracks = false
    dynamic var done_playing = true
    
    var currentHandlerType: completionHandlerType = .natural
    
    var duration_seconds: Double?
    var duration_frames: Int64?
    var track_frame_offset: Double?
    var is_paused: Bool?
    var finalBuffer: Bool?
    
    var total_offset_frames: Int64 = 0
    var total_offset_seconds: Int64 = 0
    var file_buffer_frames: Int64 = 0
    
    var mainWindowController: MainWindowController?
    
    func addListenerBlock( _ listenerBlock: @escaping AudioObjectPropertyListenerBlock, onAudioObjectID: AudioObjectID, forPropertyAddress: AudioObjectPropertyAddress) {
        var forPropertyAddress = forPropertyAddress
        if (kAudioHardwareNoError != AudioObjectAddPropertyListenerBlock(onAudioObjectID, &forPropertyAddress, nil, listenerBlock)) {
            print("Error calling: AudioObjectAddPropertyListenerBlock") }
    }
    
    override init() {
        super.init()
        addListenerBlock(audioObjectPropertyListenerBlock,
                         onAudioObjectID: AudioObjectID(bitPattern: kAudioObjectSystemObject),
                         forPropertyAddress: AudioObjectPropertyAddress(
                            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                            mScope: kAudioObjectPropertyScopeGlobal,
                            mElement: kAudioObjectPropertyElementMaster))
        
        audioEngine.attach(curPlayerNode)
        audioEngine.attach(self.equalizer)
        
        audioEngine.connect(curPlayerNode, to: equalizer, format: nil)
        audioEngine.connect(equalizer, to: audioEngine.mainMixerNode, format: nil)
    }
    
    func resetEngineCompletely() {
        self.audioEngine.reset()
    }
    
    func getDefaultAudioOutputDevice () -> AudioObjectID {
        
        var devicePropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var deviceID: AudioObjectID = 0
        var dataSize = UInt32(truncatingBitPattern: MemoryLayout<AudioDeviceID>.size)
        let systemObjectID = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        if (kAudioHardwareNoError != AudioObjectGetPropertyData(systemObjectID, &devicePropertyAddress, 0, nil, &dataSize, &deviceID)) { return 0 }
        return deviceID
    }
 
    func audioObjectPropertyListenerBlock (_ numberAddresses: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>) {
        var index: UInt32 = 0
        while index < numberAddresses {
            let address: AudioObjectPropertyAddress = addresses[0]
            switch address.mSelector {
            case kAudioHardwarePropertyDefaultOutputDevice:
                var deviceID = getDefaultAudioOutputDevice()
                print(audioEngine.isRunning)
                print(curPlayerNode.isPlaying)
                do {
                    AudioUnitSetProperty(audioEngine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
                    audioEngine.reset()
                    try audioEngine.start()
                } catch {
                    print("starting failed")
                    print(error)
                }
                print("kAudioHardwarePropertyDefaultOutputDevice: \(deviceID)")
                print(audioEngine.isRunning)
                print(curPlayerNode.isPlaying)
            default:
                print("uhh")
            }
            index += 1
        }
    }
    
    func adjustEqualizer(_ band: Int, value: Float) {
        print("adjust band called")
        guard -12 <= value && value <= 12 else {return}
        print("adjusting a band")
        let band = equalizer.bands[band]
        var defaultsEQ = equalizer.bands.map({return $0.gain})
        defaultsEQ.append(equalizer.globalGain)
        UserDefaults.standard.set(defaultsEQ, forKey: DEFAULTS_CURRENT_EQ_STRING)
        band.gain = value
    }
    
    func changeVolume(_ newVolume: Float) {
        //todo figure out why this doesnt work
        guard newVolume <= 1 && newVolume >= 0 else {return}
        audioEngine.mainMixerNode.outputVolume = newVolume
        UserDefaults.standard.set(newVolume, forKey: DEFAULTS_VOLUME_STRING)
    }
    
    func toggleEqualizer(_ state: Int) {
        if state == NSOnState {
            print("using eq")
            equalizer.bypass = false
            
        } else {
            print("no eq")
            equalizer.bypass = true
        }
    }
    
    func adjustGain(_ value: Float) {
        guard -12 <= value && value <= 12 else {return}
        equalizer.globalGain = value
    }
    
    func playNetworkImmediately(_ track: Track) {
        currentHandlerType = .destroy
        currentTrackLocation = track.location
        print("paused value is \(is_paused)")
        initializePlayback()
        play()
        print(audioEngine)
        currentHandlerType = .natural
        changeTrack()
    }
    
    func stopForNetworkTrack() {
        curPlayerNode.pause()
    }
    
    func playImmediately(_ trackLocation: String) {
        currentHandlerType = .destroy
        print("paused value is \(is_paused)")
        currentTrackLocation = trackLocation
        initializePlayback()
        if (is_paused == false || is_paused == nil) {
            print("reached play clause")
            play()
        }
        print(audioEngine)
        currentHandlerType = .natural
        changeTrack()
    }
    
    func playImmediatelyNoObservers(_ trackLocation: String) {
        currentHandlerType = .destroy
        print("paused value is \(is_paused)")
        currentTrackLocation = trackLocation
        initializePlayback()
        if (is_paused == false || is_paused == nil) {
            print("reached play clause")
            play()
        }
        print(audioEngine)
        currentHandlerType = .natural
    }
    
    func removeTracksFromQueue(_ indexes: [Int]) {
    }
    
    func addTrackToQueue(_ track: Track, index: Int?) {
        print("adding track to audio queue")
        print(index)
        print(trackQueue.count)
        if (currentTrackLocation == nil) {
            playImmediately(track.location!)
        }
        else if (trackQueue.count == 0) {
            trackQueue.append(track)
        }
        else {
            if (index != nil && index < trackQueue.count) {
                trackQueue.insert(track, at: index!)
                print("inserted \(track.name) at \(index)")
            }
            else {
                trackQueue.append(track)
            }
        }
    }
    
    
    func swapTracks(_ first_index: Int, second_index: Int) {
        if (trackQueue.count < 2) {
            return
        }
        else {
            let tmp = trackQueue[first_index]
            trackQueue[first_index] = trackQueue[second_index]
            trackQueue[second_index] = tmp
        }
    }
    
    func initializePlayback() {
        if currentTrackLocation == nil {
            return
        }
        else {
            do {
                print("initializing playback for new thing, resetting node")
                total_offset_frames = 0
                total_offset_seconds = 0
                resetEngineCompletely()
                let location = currentTrackLocation!
                let url = URL(string: location)
                if verbotenFileTypes.contains(url!.pathExtension) {
                    return
                }
                createFileBufferer(url: url!)
                let initialBuffer = self.currentFileBufferer!.prepareFirstBuffer()
                file_buffer_frames += Int64(initialBuffer!.frameLength)
                self.curPlayerNode.scheduleBuffer(initialBuffer!, completionHandler: fileBuffererCompletion)
                DispatchQueue.global(qos: .default).async {
                    self.finalBuffer = false
                    self.currentFileBufferer?.fillNextBuffer()
                }
                print("scheduling initial buffer of length \(initialBuffer!.frameLength)")
                print("file_buffer_frames is \(self.file_buffer_frames)")
                print(curFile?.processingFormat)
                print(audioEngine.outputNode)
                resetValues()
                if (audioEngine.isRunning == false) {
                    try audioEngine.start()
                }
                is_initialized = true
                self.track_frame_offset = 0
            }
            catch {
                print("audio player error: \(error)")
            }
        }
    }
    
    func changeTrack() {
        DispatchQueue.main.async {
            print("changing track")
            if self.track_changed == false {
                self.track_changed = true
            }
            else if self.track_changed == true {
                self.track_changed = false
            }
        }
    }
    
    func observerDonePlaying() {
        print("setting done playing")
        if done_playing == true {
            done_playing = false
        } else if done_playing == false {
            done_playing = true
        }
    }
    
    func getTrackLocation(_ track: Track) -> String {
        if track.is_network == false {
            return track.location!
        } else {
            return track.location!
        }
    }
    
    func tryGetMoreTracks() {
        if trackQueue.count > 0 {
            currentTrackLocation = trackQueue.removeFirst().location!
        } else {
            let nextTrack = mainWindowController?.getNextTrack()
            if nextTrack?.is_network == true {
                networkFlag = true
            }
            currentTrackLocation = nextTrack?.location
        }
    }
    
    func createFileBufferer(url: URL) {
        if url.pathExtension.lowercased() == "flac" {
            self.currentFileBufferer = FlacDecoder(file: url, audioModule: self)
            self.fileBuffererDictionary[url] = self.currentFileBufferer
        } else {
            do {
                let newFile = try AVAudioFile(forReading: url)
                self.currentFileBufferer = AVAudioFileBufferer(file: newFile, audioModule: self)
                self.fileBuffererDictionary[url] = self.currentFileBufferer
            } catch {
                print(error)
            }
        }
    }
    
    func fileBuffererCompletion() {
        //swap decode buffer
        if self.finalBuffer == true {
            //skip filling next buffer, because initial buffer of next track is already scheduled
            self.finalBuffer = false
        } else {
             self.currentFileBufferer!.fillNextBuffer()
        }
    }
    
    func fileBuffererDecodeCallback(isFinalBuffer: Bool) {
        //called when a buffer is decoded. always schedule the buffer after the end of the current one
        let newBuffer = self.currentFileBufferer!.currentDecodeBuffer
        let currentBuffer = self.currentFileBufferer!.currentDecodeBuffer == self.currentFileBufferer!.bufferA ? self.currentFileBufferer!.bufferB : self.currentFileBufferer!.bufferA
        let frameToScheduleAt = file_buffer_frames
        let time = AVAudioTime(sampleTime: frameToScheduleAt, atRate: currentBuffer.format.sampleRate)
        curPlayerNode.scheduleBuffer(newBuffer, at: time, options: .init(rawValue: 0), completionHandler: fileBuffererCompletion)
        if isFinalBuffer == true {
            file_buffer_frames += Int64(newBuffer.frameLength)
            self.finalBuffer = true
            print(self.finalBuffer)
            handleCompletion()
            //schedule next file
        } else {
            file_buffer_frames += Int64(newBuffer.frameLength)
        }
    }
    
    func handleCompletion() {
        //called any time the playback node is stopped, whether for a seek, skip, or natural playback operation ending
        //if this is the result of a scheduleFile or scheduleSegment operation, it is called after the last segment of the buffer is scheduled, not played. this is not the case for scheduleBuffer operations
        //this can probably crash all over the place if the database can't be accessed for any reason
        print("handle completion called")
        switch currentHandlerType {
        case .natural:
            tryGetMoreTracks()
            if networkFlag == true {
                networkFlag = false
                return
            }
            if (currentTrackLocation != nil) {
                print("natural next track")
                var delay: Double = 0
                do {
                    let location = currentTrackLocation!
                    let url = URL(string: location)
                    let sampleRate = curFile?.processingFormat.sampleRate ?? self.currentFileBufferer!.currentDecodeBuffer.format.sampleRate
                    let length = curFile?.length ?? (Int64(currentFileBufferer!.totalFrames))
                    let gapless_duration = AVAudioTime(sampleTime: length - Int64(track_frame_offset!), atRate: sampleRate)
                    total_offset_frames += gapless_duration.sampleTime
                    total_offset_seconds = total_offset_frames / Int64(sampleRate)
                    createFileBufferer(url: url!)
                    let initialBuffer = self.currentFileBufferer!.prepareFirstBuffer()
                    file_buffer_frames += Int64(initialBuffer!.frameLength)
                    let time = AVAudioTime(sampleTime: total_offset_frames, atRate: sampleRate)
                    print("scheduling initial buffer at frame \(total_offset_frames)")
                    curPlayerNode.scheduleBuffer(initialBuffer!, at: time, options: .init(rawValue: 0), completionHandler: fileBuffererCompletion)
                    delay = ((Double(gapless_duration.sampleTime) / gapless_duration.sampleRate) - (Double(curPlayerNode.lastRenderTime!.sampleTime - Int64(track_frame_offset!))/(curPlayerNode.lastRenderTime?.sampleRate)!))
                    print("delay set to \(delay)")
                    self.track_frame_offset = 0
                    resetValues()
                } catch {
                    print("error: \(error)")
                }
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(delay * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                    self.changeTrack()
                }
            }
            else {
                print("natural next track, no new tracks")
                let gapless_duration = AVAudioTime(sampleTime: curFile!.length, atRate: curFile!.processingFormat.sampleRate)
                let delay = ((Double(gapless_duration.sampleTime) / gapless_duration.sampleRate) - (Double(curPlayerNode.lastRenderTime!.sampleTime)/(curPlayerNode.lastRenderTime?.sampleRate)!))
                
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(delay * Double(NSEC_PER_SEC))) / Double(NSEC_PER_SEC)) {
                    //cleanly stop everything
                    self.observerDonePlaying()
                    self.total_offset_frames = 0
                    self.total_offset_seconds = 0
                    self.is_initialized = false
                    self.track_frame_offset = 0
                    self.audioEngine.reset()
                    print("done handling completion")
                }
            }
        case .seek:
            print("seek completion handler")
            //do nothing
        case .destroy:
            print("destruction")
            self.total_offset_frames = 0
            self.total_offset_seconds = 0
            self.track_frame_offset = 0
            //do nothing
        }
    }
    
    func skip() {
        tryGetMoreTracks()
        if networkFlag == true {
            currentHandlerType = .natural
            networkFlag = false
            return
        }
        currentHandlerType = .destroy
        if (currentTrackLocation != nil) {
            print("skipping to new track")
            playImmediately(currentTrackLocation!)
        }
        else {
            print("skipping, no new track")
            //cleanly stop everything
            self.observerDonePlaying()
            self.total_offset_frames = 0
            self.total_offset_seconds = 0
            self.is_initialized = false
            self.track_frame_offset = 0
            self.audioEngine.reset()
        }
        currentHandlerType = .natural
    }
    
    func skip_backward() {
        if (currentTrackLocation != nil) {
            print("skipping to new track")
            playImmediatelyNoObservers(currentTrackLocation!)
        }
        else {
            print("skipping, no new track")
            //cleanly stop everything
            self.observerDonePlaying()
            self.total_offset_frames = 0
            self.total_offset_seconds = 0
            self.is_initialized = false
            self.track_frame_offset = 0
            self.audioEngine.reset()
        }
        currentHandlerType = .natural

    }
    
    func seek(_ frac: Double) {
        let frame = Int64(frac * Double(duration_frames!))
        track_frame_offset = Double(frame)
        currentHandlerType = .seek
        curPlayerNode.stop()
        curPlayerNode.scheduleSegment(curFile!, startingFrame: frame, frameCount: UInt32(duration_frames!)-UInt32(frame), at: nil, completionHandler: handleCompletion)
        if (is_paused == false) {
            curPlayerNode.play()
            
        }
        total_offset_frames = 0
        total_offset_seconds = 0
        currentHandlerType = .natural
    }
    
    func resetValues() {
        if (curFile != nil) {
            self.duration_seconds = Double((curFile?.length)!) / (curFile?.processingFormat.sampleRate)!
            self.duration_frames = curFile?.length
        } else if self.currentFileBufferer!.bufferA != nil {
            self.duration_frames = Int64(self.currentFileBufferer!.totalFrames)
            self.duration_seconds = Double(self.duration_frames!) / self.currentFileBufferer!.bufferA.format.sampleRate
        }
    }
    
    
    func play() {
        is_paused = false
        if audioEngine.isRunning == true {
            curPlayerNode.play()
        } else {
            audioEngine.prepare()
            do {
                try audioEngine.start()
                curPlayerNode.play()
            } catch {
                print(error)
            }
        }

    }
    func pause() {
        is_paused = true
        curPlayerNode.pause()
    }
}
