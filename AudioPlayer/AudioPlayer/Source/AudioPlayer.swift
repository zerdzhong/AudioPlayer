//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by zhongzhendong on 7/27/16.
//  Copyright © 2016 zerdzhong. All rights reserved.
//

import Foundation
import AudioToolbox

enum AudioPlayerState {
    case initialized
    case startingThread
    case waitingForData
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

class AudioPlayer: NSObject {
    
    var audioURL: NSURL?
    var state: AudioPlayerState
    
    private var playerThread: NSThread?
    private var stream: CFReadStreamRef?
    private var fileLength: Int = 0
    private var seekByteOffset: Int = 0
    
    private var audioFileStreamID: AudioFileStreamID = nil
    
    private var lockQueue = dispatch_queue_create("AudioPlayer.LockQueue", nil)
    
    override init() {
        state = .initialized
        super.init()
    }
    
    convenience init(URL: NSURL) {
        self.init()
        
        audioURL = URL
    }
    
    func start() -> Void {
        if state == .initialized {
            state = .startingThread
            playerThread = NSThread(target: self, selector: #selector(startPlayerThread), object: nil)
            playerThread?.start()
        } else if state == .paused {
            // to-do pause
        }
    }
    
    @objc private func startPlayerThread() {
        
        dispatch_sync(lockQueue) {
            [unowned self] in
            
            if self.state != .startingThread {
                self.state = .initialized
                return;
            }
            
            self.openReadStream()
            
            var isRunning = true
            
            while isRunning {
                print("running...")
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
            let err = AudioFileStreamOpen(selfPointer, AudioFileStreamPropertyListener, AudioFileStreamPacketsCallback, fileType, &self.audioFileStreamID)
            
            if err != 0 {
                print("audio file stream create error:\(err)")
            }
        }
    }
    
}

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
        print("session error:\(error)")
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

func AudioFileStreamPropertyListener(clientData: UnsafeMutablePointer<Void>, audioFileStream: AudioFileStreamID, propertyID: AudioFileStreamPropertyID, ioFlag: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    
}

func AudioFileStreamPacketsCallback(clientData: UnsafeMutablePointer<Void>, numberBytes: UInt32, numberPackets: UInt32, ioData: UnsafePointer<Void>, packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>) {
    
}
