//
//  ViewController.m
//  avsbartest
//
//  Created by Aman Karmani on 12/8/21.
//

#import "ViewController.h"

@import AVFoundation;

@interface ViewController ()
@property (nonatomic, strong) AVSampleBufferAudioRenderer *renderer;
@property (nonatomic, strong) AVSampleBufferRenderSynchronizer *synchronizer;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id observer;
@end

@implementation ViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  self.renderer = [AVSampleBufferAudioRenderer new];
  self.synchronizer = [AVSampleBufferRenderSynchronizer new];
  [self.synchronizer addRenderer:self.renderer];
  self.queue = dispatch_queue_create("avsbar", 0);
  self.synchronizer.delaysRateChangeUntilHasSufficientMediaData = NO;

  [self.synchronizer setRate:0.0 time:kCMTimeZero];
  [self.renderer stopRequestingMediaData];
  [self.renderer flush];

  [self.synchronizer addObserver:self forKeyPath:@"rate" options:0 context:nil];
  [self.renderer addObserver:self forKeyPath:@"status" options:0 context:nil];

  [NSNotificationCenter.defaultCenter
      addObserverForName:AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification
      object:nil
      queue:nil
      usingBlock:^(NSNotification *notification) {
    NSValue *flushTime = [notification.userInfo objectForKey:AVSampleBufferAudioRendererFlushTimeKey];
    double time = CMTimeGetSeconds(flushTime.CMTimeValue);
    NSLog(@"renderer flush: at=%f time=%f", time, CMTimeGetSeconds(self.synchronizer.currentTime));
  }];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context{
  if ([keyPath isEqualToString:@"rate"]) {
    NSLog(@"synchronizer rate is %f", self.synchronizer.rate);
  } else if ([keyPath isEqualToString:@"status"]) {
    NSLog(@"render status is %ld (err=%@)", (long)self.renderer.status, self.renderer.error);
  }
}

- (void)viewDidAppear:(BOOL)animated{
  [super viewDidAppear:animated];
  [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongFormAudio options:0 error:nil];
  [AVAudioSession.sharedInstance setSupportsMultichannelContent:YES error:nil];
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  NSLog(@"audio session: %@", AVAudioSession.sharedInstance);
  NSLog(@"audio session port: %@", AVAudioSession.sharedInstance.currentRoute.outputs.firstObject);

  OSStatus err;
  AudioStreamBasicDescription asbd = {0};
  asbd.mSampleRate = 48000;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
  asbd.mFramesPerPacket = 1;
  asbd.mChannelsPerFrame = 2;
  asbd.mBitsPerChannel = 4 * 8;
  asbd.mBytesPerPacket = asbd.mBytesPerFrame =
    asbd.mFramesPerPacket * asbd.mChannelsPerFrame * (asbd.mBitsPerChannel / 8);
  CMFormatDescriptionRef desc;
  err = CMAudioFormatDescriptionCreate(NULL,
                                       &asbd,
                                       0, NULL,
                                       0, NULL,
                                       NULL,
                                       &desc);
  assert(err == noErr);

  __block int64_t enqueued = 0;
  __block BOOL needPlay = NO;

  self.observer = [self.synchronizer addPeriodicTimeObserverForInterval:CMTimeMake(9600, 48000) queue:nil usingBlock:^(CMTime time) {
    NSLog(@"synchronizer time = %f (enqueued = %f)", CMTimeGetSeconds(self.synchronizer.currentTime), CMTimeGetSeconds(CMTimeMake(enqueued, asbd.mSampleRate)));
  }];
  [self.synchronizer addBoundaryTimeObserverForTimes:@[[NSValue valueWithCMTime:CMTimeMake(1, 48000)]] queue:nil usingBlock:^{
    double t = CMTimeGetSeconds(self.synchronizer.currentTime);
    NSLog(@"synchronizer past zero! [%f]", t);
    /*
    if (t < 2.0) {
      [self.synchronizer setRate:1.0 time:CMTimeMake(2, 1)];
    }
    */
  }];

  [self.renderer requestMediaDataWhenReadyOnQueue:self.queue usingBlock:^{
    while (self.renderer.isReadyForMoreMediaData) {
      double enqclock = CMTimeGetSeconds(CMTimeMake(enqueued, asbd.mSampleRate));
      double synclock = CMTimeGetSeconds(self.synchronizer.currentTime);
      double delay = enqclock - synclock;
      if (delay > 1) {
        usleep(50*1000);
      }
      /*
      */

      OSStatus err;
      CMSampleBufferRef sBuf;
      CMBlockBufferRef bBuf;
      int samples = 9600;
      int bufsize = samples * 8;
      err = CMBlockBufferCreateWithMemoryBlock(
          NULL,    // structureAllocator
          NULL,    // memoryBlock
          bufsize, // blockLength
          0,       // blockAllocator
          NULL,    // customBlockSource
          0,       // offsetToData
          bufsize, // dataLength
          0,       // flags
          &bBuf
      );
      assert(err == noErr);
      err = CMBlockBufferReplaceDataBytes("\x12\x23\x34\x45\x12\x23\x34\x45", bBuf, 0, 8);
      assert(err == noErr);
      err = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
          NULL, // allocator
          bBuf, // dataBuffer
          desc, // formatDescription
          samples, // numSamples
          CMTimeMake(enqueued, asbd.mSampleRate), // timestamp
          NULL, // packetDescriptions
          &sBuf
      );
      assert(err == noErr);
      enqueued += samples;
      NSLog(@"enqueued=%lld time=%f", enqueued, CMTimeGetSeconds(self.synchronizer.currentTime));
      [self.renderer enqueueSampleBuffer:sBuf];
      if (needPlay && enqueued/(double)asbd.mSampleRate > 0.128) {
        needPlay = NO;
        NSLog(@"starting synchronizer");
        [self.synchronizer setRate:1.0];
      }
      CFRelease(sBuf);
      CFRelease(bBuf);
    }
  }];
  needPlay = YES;
}

- (void)viewWillDisappear:(BOOL)animated{
  [super viewWillDisappear:animated];
  NSLog(@"WILL DISAPPEAR");
}

- (void)viewDidDisappear:(BOOL)animated{
  [super viewDidDisappear:animated];

  NSLog(@"stopping synchronizer");
  [self.renderer stopRequestingMediaData];
  [self.renderer flush];
  [self.synchronizer setRate:0.0];
  [self.synchronizer removeTimeObserver:self.observer];
  [AVAudioSession.sharedInstance setActive:NO error:nil];
}

@end
