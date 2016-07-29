//
//  AudioPlayer.swift
//  AudioPlayer
//
//  Created by zhongzhendong on 7/27/16.
//  Copyright © 2016 zerdzhong. All rights reserved.
//

import Foundation

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
        dispatch_sync(lockQueue) {
            [unowned self] in
            assert(NSThread.currentThread().isEqual(self.playerThread))
            assert(self.stream == nil)
            assert(self.audioURL == nil)
            
            let message = CFHTTPMessageCreateRequest(nil, "GET", self.audioURL!, kCFHTTPVersion1_1).takeUnretainedValue()
            
            if self.fileLength > 0 && self.seekByteOffset > 0 {
                CFHTTPMessageSetHeaderFieldValue(message, "Range", "bytes=\(self.seekByteOffset)-\(self.fileLength)")
            }
            
//            self.stream = CFReadStreamCreateForHTTPRequest(nil, message).takeRetainedValue()
//            
//            if CFReadStreamSetProperty(self.stream, kCFStreamPropertyHTTPShouldAutoredirect, false) {
//                
//            }
            
        }
        
        return true
    }
    
}
