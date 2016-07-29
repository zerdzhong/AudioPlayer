//
//  ViewController.swift
//  AudioPlayer
//
//  Created by zhongzhendong on 7/27/16.
//  Copyright © 2016 zerdzhong. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        let player = AudioPlayer()
        player.start()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

