// SPDX-License-Identifier: GPL-3.0-or-later
#import <Cocoa/Cocoa.h>
#include "web_core.h"
#include <cstdio>
#include <stdexcept>

static void step() {
 @autoreleasepool {
  web::pump();
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  NSEvent* event;
  while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                   untilDate:[NSDate distantPast]
                                      inMode:NSDefaultRunLoopMode dequeue:YES])) {
    [NSApp sendEvent:event];
  }
 }
}

int main(int argc, char** argv) {
  setvbuf(stdout, nullptr, _IONBF, 0);
  if (argc != 3 || std::string(argv[1]) != "--smoke-test") {
    fprintf(stderr, "This bundle hosts CEF for Emacs.\nUsage: %s --smoke-test TEMP_PROFILE\n", argv[0]);
    return 2;
  }
  setenv("WEB_CEF_TEST_MODE", "1", 1);
  @autoreleasepool {
    try {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      NSWindow* first = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 800, 600)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
      first.title = @"Web native smoke";
      [first makeKeyAndOrderFront:nil];
      [NSApp finishLaunching];
      long handle;
      int id;
      @autoreleasepool {
      web::initialize(NSBundle.mainBundle.bundlePath.UTF8String, argv[2]);
      handle = web::bind_window("Web native smoke");
      id = web::create(handle,
          "data:text/html,<meta charset=utf-8><title>web-smoke-ready</title>"
          "<body style='background:%23273846;color:white;font:32px sans-serif'>"
          "CEF inside a native NSView<input placeholder='Keyboard test'></body>");
      web::layout(id, handle, 20, 40, 600, 400);
      }
      bool loaded = false, title = false;
      NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:30];
      while (deadline.timeIntervalSinceNow > 0 && !(loaded && title)) {
        step();
        auto events = web::events();
        if (events != "[]") printf("%s\n", events.c_str());
        loaded |= events.find("loaded") != std::string::npos;
        title |= events.find("web-smoke-ready") != std::string::npos;
      }
      if (!loaded || !title) throw std::runtime_error("Timed out waiting for renderer/title/load callbacks");
      @autoreleasepool { web::hide(id); }
      NSWindow* second;
      @autoreleasepool {
      second = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, 600, 450)
          styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
      second.title = @"Web second host";
      [second makeKeyAndOrderFront:nil];
        web::layout(id, web::bind_window("Web second host"), 10, 20, 500, 350);
      }
      for (int i = 0; i < 20; ++i) step();
      @autoreleasepool { web::command(id, "close", ""); }
      bool closed = false;
      deadline = [NSDate dateWithTimeIntervalSinceNow:10];
      while (deadline.timeIntervalSinceNow > 0 && !closed) {
        step();
        auto events = web::events();
        closed = events.find("closed") != std::string::npos;
      }
      if (!closed) throw std::runtime_error("Browser did not close cleanly");
      if (!first.visible || !second.visible) throw std::runtime_error("Closing browser closed a host window");
      printf("%s\n", web::info().c_str());
      web::shutdown();
      puts("PASS: renderer, navigation, layout, cross-window reparenting, hide, close, shutdown");
      return 0;
    } catch (const std::exception& error) {
      fprintf(stderr, "FAIL: %s\n", error.what());
      web::shutdown();
      return 1;
    }
  }
}
