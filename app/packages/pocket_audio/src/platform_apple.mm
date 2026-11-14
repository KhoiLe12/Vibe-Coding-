// Copyright 2026 The Pocket Studio Authors
// SPDX-License-Identifier: Apache-2.0

#include "platform.h"

#include <TargetConditionals.h>

#include <string>

#include "pocket_audio.h"

#if TARGET_OS_IOS
#import <AVFoundation/AVFoundation.h>
#endif

namespace ps {
namespace platform {

#if TARGET_OS_IOS

bool activateSession(bool withInput, bool raw) {
  @autoreleasepool {
    AVAudioSession* session = [AVAudioSession sharedInstance];
    NSError* error = nil;
    BOOL ok;
    if (withInput) {
      // Speaker (not earpiece) by default; Bluetooth/wired outputs allowed.
      // Measurement mode = no noise suppression, auto-gain or echo cancel,
      // but also no speaker loudness processing (d014: too quiet for the
      // loop pedal, which uses the default mode instead).
      ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                           mode:raw ? AVAudioSessionModeMeasurement
                                    : AVAudioSessionModeDefault
                        options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                AVAudioSessionCategoryOptionAllowBluetoothA2DP
                          error:&error];
    } else {
      // Playback ignores the silent switch.
      ok = [session setCategory:AVAudioSessionCategoryPlayback
                           mode:AVAudioSessionModeDefault
                        options:0
                          error:&error];
    }
    if (!ok) return false;
    [session setPreferredSampleRate:48000 error:nil];
    [session setPreferredIOBufferDuration:0.005 error:nil];
    return [session setActive:YES error:&error];
  }
}

void deactivateSession() {
  @autoreleasepool {
    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];
  }
}

int32_t micPermission() {
  if (@available(iOS 17.0, *)) {
    switch ([AVAudioApplication sharedInstance].recordPermission) {
      case AVAudioApplicationRecordPermissionGranted:
        return PS_MIC_GRANTED;
      case AVAudioApplicationRecordPermissionDenied:
        return PS_MIC_DENIED;
      default:
        return PS_MIC_UNDETERMINED;
    }
  }
  switch ([AVAudioSession sharedInstance].recordPermission) {
    case AVAudioSessionRecordPermissionGranted:
      return PS_MIC_GRANTED;
    case AVAudioSessionRecordPermissionDenied:
      return PS_MIC_DENIED;
    default:
      return PS_MIC_UNDETERMINED;
  }
}

void requestMicPermission() {
  if (micPermission() != PS_MIC_UNDETERMINED) return;
  if (@available(iOS 17.0, *)) {
    [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL){
    }];
  } else {
    [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL){
    }];
  }
}

bool reportedLatency(double* input, double* output, double* ioBuffer) {
  AVAudioSession* session = [AVAudioSession sharedInstance];
  *input = session.inputLatency;
  *output = session.outputLatency;
  *ioBuffer = session.IOBufferDuration;
  return true;
}

const char* outputRoute() {
  static thread_local std::string name;
  @autoreleasepool {
    AVAudioSessionRouteDescription* route =
        [AVAudioSession sharedInstance].currentRoute;
    NSString* port = route.outputs.firstObject.portType;
    name = port ? std::string(port.UTF8String) : "default";
  }
  // AVAudioSessionPortBuiltInSpeaker is "Speaker", headphones "Headphones",
  // Bluetooth "BluetoothA2DPOutput", USB "USBAudio".
  return name.c_str();
}

#else  // macOS: no audio session; TCC prompts on first capture.

bool reportedLatency(double*, double*, double*) { return false; }
const char* outputRoute() { return "default"; }

bool activateSession(bool, bool) { return true; }
void deactivateSession() {}
int32_t micPermission() { return PS_MIC_GRANTED; }
void requestMicPermission() {}

#endif

}  // namespace platform
}  // namespace ps
