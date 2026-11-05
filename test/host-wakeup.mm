// Native event-loop regression. No window is ordered on screen; no CEF/profile.
#import <Cocoa/Cocoa.h>
#include "../native/host_wakeup.h"
#include <memory>
#include <cstdio>
#include <cstring>
@interface EmacsWindow : NSWindow @end
@implementation EmacsWindow @end
static bool woke = false;
static bool expired = false;
static NSInteger receiver = 0;
@interface WakeupTestApp : NSApplication @end
@implementation WakeupTestApp
- (void)sendEvent:(NSEvent*)event {
  if (event.type == NSEventTypeApplicationDefined && event.data1 == -1) {
    woke = true;
    receiver = event.windowNumber;
    [self stop:nil];
  } else {
    [super sendEvent:event];
  }
}
@end
int main(int argc, char** argv) {
  @autoreleasepool {
    [WakeupTestApp sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    [NSApp finishLaunching];
    NSWindow* frame = [[EmacsWindow alloc] initWithContentRect:NSMakeRect(0,0,20,20)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    frame.releasedWhenClosed = NO;
    auto watcher = argc > 1 && !std::strcmp(argv[1], "--without-fix")
      ? nullptr : std::make_unique<ChromelHostWakeup>();
    // Model the native close path losing Emacs's only pending sentinel.
    NSEvent* lost = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
      location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:frame.windowNumber
      context:nil subtype:0 data1:-1 data2:0];
    [NSApp postEvent:lost atStart:NO];
    [NSApp nextEventMatchingMask:NSEventMaskApplicationDefined untilDate:NSDate.distantPast
      inMode:NSDefaultRunLoopMode dequeue:YES];
    for (int i = 0; i < 3; ++i) {
      NSWindow* auxiliary = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,20,20)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      auxiliary.releasedWhenClosed = NO;
      NSEvent* click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:auxiliary.windowNumber
        context:nil eventNumber:1 clickCount:1 pressure:1];
      if (!ChromelHostWakeup::foreignInput(click)) return 2;
      if (argc > 1 && !std::strcmp(argv[1], "--input-only")) {
        watcher->schedule();
      } else {
        [auxiliary close];
      }
    }
    NSEvent* hostClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
      location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:frame.windowNumber
      context:nil eventNumber:1 clickCount:1 pressure:1];
    if (ChromelHostWakeup::foreignInput(hostClick) || ChromelHostWakeup::foreignInput(lost)) return 2;
    bool cancelled = argc > 1 && !std::strcmp(argv[1], "--cancel");
    if (cancelled) watcher.reset();
    NSTimer* deadline = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer*) {
      expired = true;
      [NSApp stop:nil];
      [NSApp postEvent:lost atStart:NO];
    }];
    [NSApp run];
    [deadline invalidate];
    bool ok = cancelled ? expired : (woke && !expired && receiver == frame.windowNumber);
    watcher.reset();
    [frame close];
    std::printf("%s: Cocoa close wake-up, surviving frame, coalesced closes; no visible windows\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
  }
}
