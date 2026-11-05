// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Cocoa/Cocoa.h>

// Emacs exits each short NSApp.run cycle with an application-defined event.
// Native window close/tracking can discard that pending event. Lisp timers
// cannot repair the wait because they run only after NSApp.run has returned.
// Use a one-shot Cocoa timer after a foreign window closes to wake the host.
class ChromelHostWakeup {
 public:
  ChromelHostWakeup() {
    observer_ = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
      usingBlock:^(NSNotification* note) {
        Class frameClass = NSClassFromString(@"EmacsWindow");
        if (!frameClass || [note.object isKindOfClass:frameClass]) return;
        schedule();
      }];
  }
  ~ChromelHostWakeup() {
    [timer_ invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:observer_];
  }
  ChromelHostWakeup(const ChromelHostWakeup&) = delete;
  ChromelHostWakeup& operator=(const ChromelHostWakeup&) = delete;

  // Button/menu tracking may eat the host sentinel before Chromium even
  // reaches NSWindowWillClose. Wake after input dispatch too, without entering
  // Lisp or CEF recursively. Check the receiver before dispatch can destroy it.
  static bool foreignInput(NSEvent* event) {
    if (event.type != NSEventTypeLeftMouseDown && event.type != NSEventTypeRightMouseDown &&
        event.type != NSEventTypeKeyDown) return false;
    Class frameClass = NSClassFromString(@"EmacsWindow");
    return frameClass && event.window && ![event.window isKindOfClass:frameClass];
  }
  void schedule() {
    [timer_ invalidate];
    timer_ = [NSTimer timerWithTimeInterval:0.01 repeats:NO block:^(NSTimer*) {
      timer_ = nil;
      wake();
    }];
    // Run after button/menu tracking; never start a nested event loop.
    [NSRunLoop.mainRunLoop addTimer:timer_ forMode:NSDefaultRunLoopMode];
  }

 private:
  static void wake() {
    Class frameClass = NSClassFromString(@"EmacsWindow");
    for (NSWindow* window in NSApp.windows) {
      if (![window isKindOfClass:frameClass] || window.windowNumber <= 0) continue;
      // data1=-1 is Emacs's input/EINTR wake-up: recheck descriptors/timers.
      // Always target a surviving Emacs frame, not the closed Chrome window.
      NSEvent* event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
        location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
        context:nil subtype:0 data1:-1 data2:0];
      [NSApp postEvent:event atStart:NO];
      return;
    }
  }
  __strong id observer_ = nil;
  __strong NSTimer* timer_ = nil;
};
