import Foundation
import AVFoundation

@objc(PhoneRTCPlugin)
class PhoneRTCPlugin : CDVPlugin {
    var sessions: [String: Session] = [:]
    var peerConnectionFactory: RTCPeerConnectionFactory

    var videoConfig: VideoConfig?
    var videoCapturer: RTCVideoCapturer?
    var videoSource: RTCVideoSource?
    var localVideoView: RTCEAGLVideoView?
    var remoteVideoViews: [VideoTrackViewPair] = []

    var localVideoTrack: RTCVideoTrack?
    var localAudioTrack: RTCAudioTrack?

    override init(webView: UIWebView) {
        peerConnectionFactory = RTCPeerConnectionFactory()
        RTCPeerConnectionFactory.initializeSSL()
        super.init(webView: webView)

        NSNotificationCenter.defaultCenter().addObserver( self, selector: "audioRouteDidChange:", name: AVAudioSessionRouteChangeNotification, object: nil)
    }

    func createSessionObject(command: CDVInvokedUrlCommand) {
        if let sessionKey = command.argumentAtIndex(0) as? String {
            // create a session and initialize it.
            if let args: AnyObject = command.argumentAtIndex(1) {
                let config = SessionConfig(data: args)
                let session = Session(plugin: self, peerConnectionFactory: peerConnectionFactory,
                    config: config, callbackId: command.callbackId,
                    sessionKey: sessionKey)
                sessions[sessionKey] = session
            }
        }
    }

    func call(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            dispatch_async(dispatch_get_main_queue()) {
                if let session = self.sessions[sessionKey] {
                    session.call()
                }
            }
        }
    }

    func receiveMessage(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            if let message = args.objectForKey("message") as? String {
                if let session = self.sessions[sessionKey] {
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
                        session.receiveMessage(message)
                    }
                }
            }
        }
    }

    func renegotiate(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            if let config: AnyObject = args.objectForKey("config") {
                dispatch_async(dispatch_get_main_queue()) {
                    if let session = self.sessions[sessionKey] {
                        session.config = SessionConfig(data: config)
                        session.createOrUpdateStream()
                    }
                }
            }
        }
    }

    func disconnect(command: CDVInvokedUrlCommand) {
        let args: AnyObject = command.argumentAtIndex(0)
        if let sessionKey = args.objectForKey("sessionKey") as? String {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
                if (self.sessions[sessionKey] != nil) {
                    self.sessions[sessionKey]!.disconnect(true)
                }
            }
        }
    }

    func sendMessage(callbackId: String, message: NSData) throws {
        let json = try NSJSONSerialization.JSONObjectWithData(message,
            options: NSJSONReadingOptions.MutableLeaves) as! NSDictionary

        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsDictionary: json as! [NSObject : AnyObject])
        pluginResult.setKeepCallbackAsBool(true);

        self.commandDelegate!.sendPluginResult(pluginResult, callbackId:callbackId)
    }

    func setVideoView(command: CDVInvokedUrlCommand) {
        let config: AnyObject = command.argumentAtIndex(0)

        dispatch_async(dispatch_get_main_queue()) {
            // create session config from the JS params
            let videoConfig = VideoConfig(data: config)

            self.videoConfig = videoConfig

            // make sure that it's not junk
            if videoConfig.container.width == 0 || videoConfig.container.height == 0 {
                return
            }

            // add local video view
            if self.videoConfig!.local != nil {
                if self.localVideoTrack == nil {
                    self.initLocalVideoTrack()
                }

                if self.videoConfig!.local == nil {
                    // remove the local video view if it exists and
                    // the new config doesn't have the `local` property
                    if self.localVideoView != nil {
                        self.localVideoView!.hidden = true
                        self.localVideoView!.removeFromSuperview()
                        self.localVideoView = nil
                    }
                } else {
                    let params = self.videoConfig!.local!

                    // if the local video view already exists, just
                    // change its position according to the new config.
                    if self.localVideoView != nil {

                        // Lets handle the resize on "connected" event
                        /*
                        self.localVideoView!.frame = CGRectMake(
                            CGFloat(params.x + self.videoConfig!.container.x),
                            CGFloat(params.y + self.videoConfig!.container.y),
                            CGFloat(params.width),
                            CGFloat(params.height)
                        )
                        */
                    } else {
                        // otherwise, create the local video view
                        self.localVideoView = self.createVideoView(params)
                        self.localVideoTrack!.addRenderer(self.localVideoView!)
                    }
                }

                self.refreshVideoContainer()
            }
        }
    }

    func hideVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            self.localVideoView!.hidden = true;

            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.videoView.hidden = true;
            }
        }
    }

    func showVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            self.localVideoView!.hidden = false;

            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.videoView.hidden = false;
            }
        }
    }

    //az - custom routine to handle call reset when session is not established
    func reset( command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {

            if self.localVideoView != nil {
                self.localVideoView!.hidden = true
                self.localVideoView!.removeFromSuperview()

                self.localVideoView = nil
            }
        }

        self.localVideoTrack = nil
        self.localAudioTrack = nil

        self.videoSource = nil
        self.videoCapturer = nil
    }

    func createVideoView(params: VideoLayoutParams? = nil) -> RTCEAGLVideoView {
        var view: RTCEAGLVideoView

        if params != nil {
            let frame = CGRectMake(
                CGFloat(params!.x + self.videoConfig!.container.x),
                CGFloat(params!.y + self.videoConfig!.container.y),
                CGFloat(params!.width),
                CGFloat(params!.height)
            )

            view = RTCEAGLVideoView(frame: frame)
        } else {
            view = RTCEAGLVideoView()
        }

        view.userInteractionEnabled = false

        self.webView!.insertSubview(view, atIndex: 1)
        self.webView!.opaque = false
        self.webView!.backgroundColor = UIColor.clearColor()

        return view
    }

    func initLocalAudioTrack() {
        localAudioTrack = peerConnectionFactory.audioTrackWithID("ARDAMSa0")
        //az AudioSession Override
        self.setupAudioSession()
    }

    func initLocalVideoTrack() {
        var cameraID: String?
        let position: AVCaptureDevicePosition = AVCaptureDevicePosition.Front

        /*
        if (self.videoConfig?.rearFacingCamera == true) {
            position = AVCaptureDevicePosition.Back
        }
        */

        for captureDevice in AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo) {

            if captureDevice.position == position {
                cameraID = captureDevice.localizedName
            }
        }

        self.videoCapturer = RTCVideoCapturer(deviceName: cameraID)
        self.videoSource = self.peerConnectionFactory.videoSourceWithCapturer(
            self.videoCapturer,
            constraints: RTCMediaConstraints()
        )

        self.localVideoTrack = self.peerConnectionFactory
            .videoTrackWithID("ARDAMSv0", source: self.videoSource)
    }

    func addRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        if self.videoConfig == nil {
            return
        }

        // add a video view without position/size as it will get
        // resized and re-positioned in refreshVideoContainer
        let videoView = createVideoView()

        videoTrack.addRenderer(videoView)
        self.remoteVideoViews.append(VideoTrackViewPair(videoView: videoView, videoTrack: videoTrack))

        refreshVideoContainer()

        if self.localVideoView != nil {
            self.webView!.bringSubviewToFront(self.localVideoView!)
        }
    }

    func removeRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        dispatch_async(dispatch_get_main_queue()) {
            for var i = 0; i < self.remoteVideoViews.count; i++ {
                let pair = self.remoteVideoViews[i]
                if pair.videoTrack == videoTrack {
                    pair.videoView.hidden = true
                    pair.videoView.removeFromSuperview()
                    self.remoteVideoViews.removeAtIndex(i)
                    self.refreshVideoContainer()
                    return
                }
            }
        }
    }

    func refreshVideoContainer() {
        var n = self.remoteVideoViews.count

        if ( n == 0 ) {

            if self.localVideoView != nil {
                self.localVideoView!.frame = CGRectMake(
                    CGFloat(self.videoConfig!.container.x),
                    CGFloat(self.videoConfig!.container.y),
                    CGFloat(self.videoConfig!.container.width),
                    CGFloat(self.videoConfig!.container.height)
                )
            }
            return

        } else {
          //az - do nothing, handle resize onSessionConnect()
        }

        if n > 1 {
            n = n - 1
        }

        let rows = n < 9 ? 2 : 3
        let videosInRow = n == 2 ? 2 : Int(ceil(Float(n) / Float(rows)))

        let videoSize = Int(Float(self.videoConfig!.container.width) / Float(videosInRow))
        let actualRows = Int(ceil(Float(n) / Float(videosInRow)))

        var y = getCenter(actualRows,
            videoSize: videoSize,
            containerSize: self.videoConfig!.container.height)
                + self.videoConfig!.container.y

        var videoViewIndex = 0

        for var row = 0; row < rows && videoViewIndex < n; row++ {
            var x = getCenter(row < row - 1 || n % rows == 0 ?
                                videosInRow : n - (min(n, videoViewIndex + videosInRow) - 1),
                videoSize: videoSize,
                containerSize: self.videoConfig!.container.width)
                    + self.videoConfig!.container.x

            var startIndex = 0
            if n > 1 {
                startIndex = 1

                self.remoteVideoViews[0].videoView.frame = CGRectMake(
                    CGFloat(self.videoConfig!.container.x),
                    CGFloat(self.videoConfig!.container.y),
                    CGFloat(self.videoConfig!.container.width),
                    CGFloat(self.videoConfig!.container.height)
                )

            }

            for var video = 0; video < videosInRow && videoViewIndex < n; video++ {
                let pair = self.remoteVideoViews[videoViewIndex++]
                pair.videoView.frame = CGRectMake(
                    CGFloat(x),
                    CGFloat(y),
                    CGFloat(videoSize),
                    CGFloat(videoSize)
                )

                x += Int(videoSize)
            }

            y += Int(videoSize)
        }
    }

    func getCenter(videoCount: Int, videoSize: Int, containerSize: Int) -> Int {
        return lroundf(Float(containerSize - videoSize * videoCount) / 2.0)
    }

    func onSessionDisconnect(sessionKey: String) {
        self.sessions.removeValueForKey(sessionKey)

        if self.sessions.count == 0 {
            dispatch_sync(dispatch_get_main_queue()) {
                if self.localVideoView != nil {
                    self.localVideoView!.hidden = true
                    self.localVideoView!.removeFromSuperview()

                    self.localVideoView = nil
                }
            }

            self.localVideoTrack = nil
            self.localAudioTrack = nil

            self.videoSource = nil
            self.videoCapturer = nil
        }
    }

    func onSessionConnected() {
        print("Calling onSessionConnected")

        /*
        if (self.videoConfig?.isAudioCall != false) {
            return
        }
        */

        let params = self.videoConfig!.local!

        if ( self.localVideoView != nil ) {

            print("resizing")
            self.localVideoView?.layer.borderColor = UIColor.whiteColor().CGColor
            self.localVideoView?.layer.borderWidth = 1.0

            self.resizeLocalVideoView("thumb")
        }
        if self.localVideoView != nil {
            self.webView!.bringSubviewToFront(self.localVideoView!)
        }
    }

    func resizeLocalVideoView(toSize:NSString) {
        switch(toSize) {
        case "large" :
            print("resizing to large")

            let currentFrame = self.localVideoView!.frame

            if (currentFrame.width == CGFloat(self.videoConfig!.container.width)) {
                return
            }

            let translate = CGAffineTransformMakeTranslation (0 , 0)
            let scale  = CGAffineTransformMakeScale(CGFloat(self.videoConfig!.container.width)/currentFrame.width , CGFloat(self.videoConfig!.container.height)/currentFrame.height)

            UIView.animateWithDuration(0.5, animations: { () -> Void in
                self.localVideoView?.transform = CGAffineTransformConcat(scale, translate)
                return
            })


        case "thumb" :
            print("resizing to thumb")

            let params = self.videoConfig!.local!

            let currentFrame = self.localVideoView!.frame
            if (currentFrame.width == CGFloat(params.width)) {
                return
            }
            let translate = CGAffineTransformMakeTranslation (0 - CGFloat((self.videoConfig!.container.width - params.width)/2) + CGFloat(params.x) , 0 - CGFloat((self.videoConfig!.container.height - params.height)/2) + CGFloat(params.y))
            let scale  = CGAffineTransformMakeScale(CGFloat(params.width)/currentFrame.width , CGFloat(params.height)/currentFrame.height)


            UIView.animateWithDuration(0.5, animations: { () -> Void in
                self.localVideoView?.transform = CGAffineTransformConcat(scale, translate)
                return
            })


        default:
            print("do nothing")
        }
    }

    func setupAudioSession () {
        //  az added to override any audio conflict from other plugins
        /*
            https://developer.apple.com/library/ios/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html#//apple_ref/doc/uid/TP40007875-CH3-SW1
        */

        print("Setting up audio session")

        var error : NSError?;
        let auSession = AVAudioSession.sharedInstance()

        print("Current audioRoute : \(auSession.currentRoute)")

        if self.isHeadphonePluggedIn() {
            print("setupAudioSession: On headphone, no need to override to speaker")
            return
        }

        
        //  Signals are optimized for voice through system-supplied signal processing and sets AVAudioSessionCategoryOptionAllowBluetooth and AVAudioSessionCategoryOptionDefaultToSpeaker.
        do {
            try auSession.setMode(AVAudioSessionModeVoiceChat)
        } catch {
            
        }


        //  Tell other audio units to resume playing audio if they were interrupted with this call
        do {
            try auSession.setActive(true)
        } catch {
            
        }

        //  Lets route to speaker
        do {
            try auSession.overrideOutputAudioPort(AVAudioSessionPortOverride.Speaker)
        } catch {
            
        }
        

    }

    func audioRouteDidChange(notification: NSNotification) {
        var interuptionDict:NSDictionary = notification.userInfo!
        var routeChangeReason: NSInteger = interuptionDict.valueForKey(AVAudioSessionRouteChangeReasonKey)!.integerValue

        var error : NSError?;
        let auSession = AVAudioSession.sharedInstance()

        switch (routeChangeReason) {
        case AVAudioSessionRouteChangeReason.CategoryChange.hashValue:
            // Set speaker as default route

            print("change audioRoute before: \(auSession.currentRoute)")

            if self.isHeadphonePluggedIn() {
                print("On headphone, no need to override to speaker")
                return
            }

            do  {
                try auSession.overrideOutputAudioPort(AVAudioSessionPortOverride.Speaker)
            } catch {
                
            }

            break

        case AVAudioSessionRouteChangeReason.NewDeviceAvailable.hashValue:
            print("AVAudioSessionRouteChangeReasonNewDeviceAvailable");
            print("Headphone/Line plugged in");
            break;

        case AVAudioSessionRouteChangeReason.OldDeviceUnavailable.hashValue:
            print("AVAudioSessionRouteChangeReasonOldDeviceUnavailable");
            print("Headphone/Line was pulled. switching to speaker....");

            do {
                try auSession.overrideOutputAudioPort(AVAudioSessionPortOverride.Speaker)
            } catch {
                
            }
            
            break;

        default:
            break
        }
    }

    func isHeadphonePluggedIn() -> Bool {
        let auSession = AVAudioSession.sharedInstance()
        for desc in auSession.currentRoute.outputs {
            if desc.portType == AVAudioSessionPortHeadphones {
                return true
            }
        }
        return false
    }
}

struct VideoTrackViewPair {
    var videoView: RTCEAGLVideoView
    var videoTrack: RTCVideoTrack
}
