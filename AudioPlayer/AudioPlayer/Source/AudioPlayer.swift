//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by zhongzhendong on 7/27/16.
//  Copyright © 2016 zerdzhong. All rights reserved.
//

import Foundation
import AudioToolbox
import AVFoundation

enum AudioPlayerState {
    case initialized
    case startingThread
    case waitingForData
    case flushingEoF
    case watingForQueueStart
    case playing
    case buffing
    case stopping
    case stopped
    case paused
}

enum AudioPlayerError: ErrorType {
    case connectionFailed
    case fileStreamGetPropertyFailed
    case fileStreamSetPropertyFailed
    case audioDataNotFound
}

let kAQDefaultBufSize: UInt32 = 2048
let kNumberBuffers: Int = 3
let kAQMaxPacketDescs: Int = 512

class AudioPlayer: NSObject {
    
    var audioURL: NSURL?
    var state: AudioPlayerState
    
    private var playerThread: NSThread?
    private var stream: CFReadStreamRef?
    private var fileLength: Int = 0
    private var seekByteOffset: Int = 0
    
    //MARK: - Audio propertys
    private var audioFileStreamID: AudioFileStreamID = nil
    private var audioBaseDescription = AudioStreamBasicDescription()
    private var audioQueue: AudioQueueRef = nil
    private var packetBufferSize: UInt32 = 0
    private var audioQueueBuffers = Array<AudioQueueBufferRef>(count: kNumberBuffers, repeatedValue: nil)
    
    private var packetDescs = Array<AudioStreamPacketDescription>(count: kAQMaxPacketDescs, repeatedValue: AudioStreamPacketDescription())
    private var packetsFilled: UInt32 = 0
    private var bytesFilled: UInt32 = 0
    private var inUse = Array<Bool>(count: kNumberBuffers, repeatedValue: false)
    private var fillBufferIndex: Int = 0
    private var bufferUsed: Int = 0
    private var audioDataByteCount: Int = 0
    private var dataOffset: Int = 0
    
    private var lockQueue = dispatch_queue_create("AudioPlayer.LockQueue", nil)
    
    //MARK:- life cycle
    override init() {
        state = .initialized
        super.init()
    }
    
    convenience init(URL: NSURL) {
        self.init()
        
        audioURL = URL
    }
    
    //MARK: - public func
    func start() -> Void {
        if state == .initialized {
            state = .startingThread
            playerThread = NSThread(target: self, selector: #selector(startPlayerThread), object: nil)
            playerThread?.start()
        } else if state == .paused {
            // to-do pause
        }
    }
    
    //MARK: - private func
    @objc private func startPlayerThread() {
        
        dispatch_sync(lockQueue) {
            [unowned self] in
            
            if self.state != .startingThread {
                self.state = .initialized
                return;
            }
            
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch let error as NSError {
                print("AVAudioSession set active error\(error)")
            }
            
            
            self.openReadStream()
            
            var isRunning = true
            
            while isRunning {
//                print("running...")
                isRunning = NSRunLoop.currentRunLoop().runMode(NSDefaultRunLoopMode, beforeDate: NSDate(timeIntervalSinceNow: 0.25))
            }
        }
    }
    
    private func openReadStream() -> Bool {
        
        assert(NSThread.currentThread().isEqual(self.playerThread))
        assert(self.stream == nil)
        assert(self.audioURL != nil)
        
        let urlSession = NSURLSession(configuration: NSURLSessionConfiguration.defaultSessionConfiguration(), delegate: self, delegateQueue: nil)
        
        let dataRequest = NSURLRequest(URL: self.audioURL!)
        
        if self.fileLength > 0 && self.seekByteOffset > 0 {
            dataRequest.setValue("bytes=\(self.seekByteOffset)-\(self.fileLength))", forKey: "Range")
        }
        
        let dataTask = urlSession.dataTaskWithRequest(dataRequest)
        
        dataTask.resume()
        
        return true
    }
    
    private func setupAudioFileStream() {
        if audioFileStreamID != nil {
            return
        }
        
        assert(self.audioURL != nil)
            
        if let fileExtension = self.audioURL?.pathExtension {
            let fileType = self.hintForFileExtension(fileExtension)
            
            let selfPointer = unsafeBitCast(self, UnsafeMutablePointer<Void>.self)
            let status = AudioFileStreamOpen(selfPointer, AudioFileStreamPropertyListener, AudioFileStreamPacketsCallback, fileType, &self.audioFileStreamID)
            
            if noErr != status {
                print("audio file stream create error:\(status)")
            }
        }
    }
    
    private func setupAudioQueue() {
        
        if audioQueue != nil {
            return
        }
        
        var status: OSStatus = 0
        
        let inUserPointer = unsafeBitCast(self, UnsafeMutablePointer<Void>.self)
        status = AudioQueueNewOutput(&audioBaseDescription, AudioQueueOutputCallback, inUserPointer, nil, nil, 0, &audioQueue)
        assert(noErr == status)
        
        status = AudioQueueAddPropertyListener(audioQueue, kAudioQueueProperty_IsRunning, AudioQueueRunningListener, inUserPointer)
        assert(noErr == status)
        
        var propertySize = UInt32(sizeof(UInt32))
        
        status = AudioFileStreamGetProperty(audioFileStreamID, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &packetBufferSize)
        
        if noErr != status || packetBufferSize == 0 {
            status = AudioFileStreamGetProperty(audioFileStreamID, kAudioFileStreamProperty_MaximumPacketSize, &propertySize, &packetBufferSize)
            if noErr != status || packetBufferSize == 0 {
                packetBufferSize = kAQDefaultBufSize
            }
        }
        
        for index in 0..<kNumberBuffers {
            status = AudioQueueAllocateBuffer(audioQueue, packetBufferSize, &audioQueueBuffers[index])
            assert(noErr == status)
        }
        
        var cookieSize = UInt32(sizeof(UInt32))
        
        let couldNotGetProperty = (AudioFileStreamGetPropertyInfo(audioFileStreamID, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == 0)
        
        if !couldNotGetProperty && cookieSize > 0 {
            let magicCookie = UnsafeMutablePointer<Void>(malloc(Int(cookieSize)))
            
            AudioFileStreamGetProperty(audioFileStreamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, magicCookie)
            AudioQueueSetProperty(audioFileStreamID, kAudioQueueProperty_MagicCookie, magicCookie, cookieSize)
            
            free(magicCookie)
        }
    }
    
    private func enqueueBuffer() {
        
        print("enqueue buffer")
        
        inUse[fillBufferIndex] = true
        bufferUsed += 1
        
        let fillBuffer = audioQueueBuffers[fillBufferIndex]
        fillBuffer.memory.mAudioDataByteSize = bytesFilled
        
        var status: OSStatus = 0
        
        if packetsFilled > 0 {
            status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, packetsFilled, packetDescs)
        } else {
            status = AudioQueueEnqueueBuffer(audioQueue, fillBuffer, 0, nil)
        }
        
        if noErr != status {
            print("AudioQueue enqueue error")
            return
        }
        
        if state == .buffing || state == .waitingForData || state == .flushingEoF {
            if state == .flushingEoF || bufferUsed == kNumberBuffers - 1 {
                if state == .buffing {
                    status = AudioQueueStart(audioQueue, nil)
                    assert(noErr == status)
                    state = .playing
                } else {
                    state = .watingForQueueStart
                    
                    status = AudioQueueStart(audioQueue, nil)
                    assert(noErr == status)
                }
            }
        }
        
        fillBufferIndex += 1
        
        if fillBufferIndex >= kNumberBuffers {
            fillBufferIndex = 0
        }
        
        bytesFilled = 0
        packetsFilled = 0
    }
    
    //MARK: -
    
    private func handleAudioPackets(numberOfPackets: UInt32, numberOfBytes: UInt32, data: UnsafePointer<Void>, packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>) {
        print("handle audio packets")
        
        if audioQueue == nil {
            setupAudioQueue()
        }
        
        if packetDescription != nil {
            for index: Int in 0..<Int(numberOfPackets) {
                let packetOffset = packetDescription.advancedBy(index).memory.mStartOffset
                let packetSize = packetDescription.advancedBy(index).memory.mDataByteSize
                
                let remainSpace = packetBufferSize - bytesFilled
                
                if remainSpace < packetSize {
                    enqueueBuffer()
                }
                
                if bytesFilled + packetSize > packetBufferSize {
                    return
                }
                
                let fillBuffer = audioQueueBuffers[fillBufferIndex]
                memcpy(fillBuffer.advancedBy(Int(bytesFilled)), data.advancedBy(Int(packetOffset)), Int(packetSize))
                
                packetDescs[Int(packetsFilled)] = packetDescription.advancedBy(index).memory
                packetDescs[Int(packetsFilled)].mStartOffset = Int64(bytesFilled)
                
                bytesFilled += packetSize
                packetsFilled += 1
            }
            
            if kAQMaxPacketDescs - Int(packetsFilled) == 0{
                enqueueBuffer()
            }
        } else {
            
        }
    }
    
    private func handlePropertyChange(audioFileStream: AudioFileStreamID, fileStreamPropertyID: AudioFileStreamPropertyID, ioFlags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
        print("audio file stream property change")
        
        if fileStreamPropertyID == kAudioFileStreamProperty_ReadyToProducePackets {
            
        } else if fileStreamPropertyID == kAudioFileStreamProperty_DataOffset {
            
            var offset: Int = 0
            var offsetSize = UInt32(sizeof(UInt64))
            let status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset)
            
            if noErr == status {
                return
            }
            
            dataOffset = offset
            
            if audioDataByteCount > 0 {
                fileLength = dataOffset + audioDataByteCount
            }
            
        } else if fileStreamPropertyID == kAudioFileStreamProperty_AudioDataByteCount {
            
            var byteCountSize = UInt32(sizeof(UInt64))
            AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount)
            
            fileLength = dataOffset + audioDataByteCount
            
        } else if fileStreamPropertyID == kAudioFileStreamProperty_DataFormat {
            if audioBaseDescription.mSampleRate == 0 {
                var dataFormatSize = UInt32(sizeof(AudioStreamBasicDescription))
                let status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_DataFormat, &dataFormatSize, &audioBaseDescription)
                assert(noErr == status)
            }
        } else if fileStreamPropertyID == kAudioFileStreamProperty_FormatList {
            
            var outWriteable: Bool = false
            var formatListSize = UInt32(sizeof(Bool))
            
            var status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable)
            
            assert(noErr == status)
            
            let formatList = UnsafeMutablePointer<AudioFormatListItem>(malloc(Int(formatListSize)))
            
            status = AudioFileStreamGetProperty(audioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList)
            
            if noErr != status {
                free(formatList)
                return
            }
            
            var index: UInt32 = 0
            
            while index * UInt32(sizeof(AudioFormatListItem)) < formatListSize {
                let streamDesc = formatList.advancedBy(Int(index)).memory.mASBD
                
                if streamDesc.mFormatID == kAudioFormatMPEG4AAC_HE || streamDesc.mFormatID == kAudioFormatMPEG4AAC_HE_V2 {
                    audioBaseDescription = streamDesc
                    break
                }
                
                free(formatList)
                
                index += UInt32(sizeof(AudioFormatListItem))
            }
            
        }
    }
    
}

//MARK: - AudioPlayer urlSession delegate
extension AudioPlayer: NSURLSessionDataDelegate
{
    
    func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveResponse response: NSURLResponse, completionHandler: (NSURLSessionResponseDisposition) -> Void) {
        
        completionHandler(.Allow)
        
        if self.fileLength != 0 {
            return
        }
        
        self.fileLength = Int(response.expectedContentLength) + self.seekByteOffset
        
        print("receive response, file length:\(self.fileLength)")
    }
    
    func URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData data: NSData) {
        self.seekByteOffset += data.length
        print("currentLength:\(self.seekByteOffset)-totalLength:\(self.fileLength)")
        
        setupAudioFileStream()
        
        AudioFileStreamParseBytes(self.audioFileStreamID, UInt32(data.length), data.bytes, AudioFileStreamParseFlags(rawValue: 0))
    }
    
    func URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError error: NSError?) {
        if let err = error {
            print("session error:\(err)")
        }
    }
}

extension AudioPlayer
{
    private func hintForFileExtension(fileExtension: String) -> AudioFileTypeID {
        var fileTypeHint: AudioFileTypeID = kAudioFileAAC_ADTSType;
        
        switch fileExtension {
        case "mp3":
            fileTypeHint = kAudioFileMP3Type;
            break
        case "wav":
            fileTypeHint = kAudioFileWAVEType;
            break
        case "aifc":
            fileTypeHint = kAudioFileAIFCType;
            break
        case "aiff":
            fileTypeHint = kAudioFileAIFFType;
            break
        case "m4a":
            fileTypeHint = kAudioFileM4AType;
            break
        case "mp4":
            fileTypeHint = kAudioFileMPEG4Type;
            break
        case "caf":
            fileTypeHint = kAudioFileCAFType;
            break
        case "aac":
            fileTypeHint = kAudioFileAAC_ADTSType;
            break
        default:
            break
        }
        
        return fileTypeHint;
    }
}

//MARK: - AudioFileStream callback

func AudioFileStreamPropertyListener(clientData: UnsafeMutablePointer<Void>, audioFileStream: AudioFileStreamID, propertyID: AudioFileStreamPropertyID, ioFlag: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    let this = Unmanaged<AudioPlayer>.fromOpaque(COpaquePointer(clientData)).takeUnretainedValue()
    this.handlePropertyChange(audioFileStream, fileStreamPropertyID: propertyID, ioFlags: ioFlag)
}

func AudioFileStreamPacketsCallback(clientData: UnsafeMutablePointer<Void>, numberBytes: UInt32, numberPackets: UInt32, ioData: UnsafePointer<Void>, packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>) {
    
    let this = Unmanaged<AudioPlayer>.fromOpaque(COpaquePointer(clientData)).takeUnretainedValue()
    this.handleAudioPackets(numberPackets, numberOfBytes: numberBytes, data: ioData, packetDescription: packetDescription)
}

//MARK: - AudioQueue callback
func AudioQueueOutputCallback(clientData: UnsafeMutablePointer<Void>, AQ: AudioQueueRef, buffer: AudioQueueBufferRef) {
    
}

func AudioQueueRunningListener(clientData: UnsafeMutablePointer<Void>, AQ: AudioQueueRef, propertyID: AudioQueuePropertyID) {
}