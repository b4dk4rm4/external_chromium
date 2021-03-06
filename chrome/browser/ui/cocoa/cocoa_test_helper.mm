// Copyright (c) 2009 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "chrome/browser/ui/cocoa/cocoa_test_helper.h"

#include "base/debug/debugger.h"
#include "base/logging.h"
#include "base/mac/mac_util.h"
#include "base/test/test_timeouts.h"
#import "chrome/browser/chrome_browser_application_mac.h"

@implementation CocoaTestHelperWindow

- (id)initWithContentRect:(NSRect)contentRect {
  return [self initWithContentRect:contentRect
                         styleMask:NSBorderlessWindowMask
                           backing:NSBackingStoreBuffered
                             defer:NO];
}

- (id)init {
  return [self initWithContentRect:NSMakeRect(0, 0, 800, 600)];
}

- (void)dealloc {
  // Just a good place to put breakpoints when having problems with
  // unittests and CocoaTestHelperWindow.
  [super dealloc];
}

- (void)makePretendKeyWindowAndSetFirstResponder:(NSResponder*)responder {
  EXPECT_TRUE([self makeFirstResponder:responder]);
  [self setPretendIsKeyWindow:YES];
}

- (void)clearPretendKeyWindowAndFirstResponder {
  [self setPretendIsKeyWindow:NO];
  EXPECT_TRUE([self makeFirstResponder:NSApp]);
}

- (void)setPretendIsKeyWindow:(BOOL)flag {
  pretendIsKeyWindow_ = flag;
}

- (BOOL)isKeyWindow {
  return pretendIsKeyWindow_;
}

@end

CocoaTest::CocoaTest() : called_tear_down_(false), test_window_(nil) {
  BootstrapCocoa();

  // Set the duration of AppKit-evaluated animations (such as frame changes)
  // to zero for testing purposes. That way they take effect immediately.
  [[NSAnimationContext currentContext] setDuration:0.0];

  // The above does not affect window-resize time, such as for an
  // attached sheet dropping in.  Set that duration for the current
  // process (this is not persisted).  Empirically, the value of 0.0
  // is ignored.
  NSDictionary* dict =
      [NSDictionary dictionaryWithObject:@"0.01" forKey:@"NSWindowResizeTime"];
  [[NSUserDefaults standardUserDefaults] registerDefaults:dict];

  // Collect the list of windows that were open when the test started so
  // that we don't wait for them to close in TearDown. Has to be done
  // after BootstrapCocoa is called.
  initial_windows_ = ApplicationWindows();
}

CocoaTest::~CocoaTest() {
  // Must call CocoaTest's teardown from your overrides.
  DCHECK(called_tear_down_);
}

void CocoaTest::BootstrapCocoa() {
  // Look in the framework bundle for resources.
  FilePath path;
  PathService::Get(base::DIR_EXE, &path);
  path = path.Append(chrome::kFrameworkName);
  base::mac::SetOverrideAppBundlePath(path);

  // Bootstrap Cocoa. It's very unhappy without this.
  [CrApplication sharedApplication];
}

void CocoaTest::TearDown() {
  called_tear_down_ = true;
  // Call close on our test_window to clean it up if one was opened.
  [test_window_ close];
  test_window_ = nil;

  // Recycle the pool to clean up any stuff that was put on the
  // autorelease pool due to window or windowcontroller closures.
  pool_.Recycle();

  // Some controls (NSTextFields, NSComboboxes etc) use
  // performSelector:withDelay: to clean up drag handlers and other
  // things (Radar 5851458 "Closing a window with a NSTextView in it
  // should get rid of it immediately").  The event loop must be spun
  // to get everything cleaned up correctly.  It normally only takes
  // one to two spins through the event loop to see a change.

  // NOTE(shess): Under valgrind, -nextEventMatchingMask:* in one test
  // needed to run twice, once taking .2 seconds, the next time .6
  // seconds.  The loop exit condition attempts to be scalable.

  // Get the set of windows which weren't present when the test
  // started.
  std::set<NSWindow*> windows_left(WindowsLeft());

  while (!windows_left.empty()) {
    // Cover delayed actions by spinning the loop at least once after
    // this timeout.
    const NSTimeInterval kCloseTimeoutSeconds =
        TestTimeouts::action_timeout_ms() / 1000.0;

    // Cover chains of delayed actions by spinning the loop at least
    // this many times.
    const int kCloseSpins = 3;

    // Track the set of remaining windows so that everything can be
    // reset if progress is made.
    std::set<NSWindow*> still_left = windows_left;

    NSDate* start_date = [NSDate date];
    bool one_more_time = true;
    int spins = 0;
    while (still_left.size() == windows_left.size() &&
           (spins < kCloseSpins || one_more_time)) {
      // Check the timeout before pumping events, so that we'll spin
      // the loop once after the timeout.
      one_more_time =
          ([start_date timeIntervalSinceNow] > -kCloseTimeoutSeconds);

      // Autorelease anything thrown up by the event loop.
      {
        base::mac::ScopedNSAutoreleasePool pool;
        ++spins;
        NSEvent *next_event = [NSApp nextEventMatchingMask:NSAnyEventMask
                                                 untilDate:nil
                                                    inMode:NSDefaultRunLoopMode
                                                   dequeue:YES];
        [NSApp sendEvent:next_event];
        [NSApp updateWindows];
      }

      // Refresh the outstanding windows.
      still_left = WindowsLeft();
    }

    // If no progress is being made, log a failure and continue.
    if (still_left.size() == windows_left.size()) {
      // NOTE(shess): Failing this expectation means that the test
      // opened windows which have not been fully released.  Either
      // there is a leak, or perhaps one of |kCloseTimeoutSeconds| or
      // |kCloseSpins| needs adjustment.
      EXPECT_EQ(0U, windows_left.size());
      for (std::set<NSWindow*>::iterator iter = windows_left.begin();
           iter != windows_left.end(); ++iter) {
        const char* desc = [[*iter description] UTF8String];
        LOG(WARNING) << "Didn't close window " << desc;
      }
      break;
    }

    windows_left = still_left;
  }
  PlatformTest::TearDown();
}

std::set<NSWindow*> CocoaTest::ApplicationWindows() {
  // This must NOT retain the windows it is returning.
  std::set<NSWindow*> windows;

  // Must create a pool here because [NSApp windows] has created an array
  // with retains on all the windows in it.
  base::mac::ScopedNSAutoreleasePool pool;
  NSArray *appWindows = [NSApp windows];
  for (NSWindow *window in appWindows) {
    windows.insert(window);
  }
  return windows;
}

std::set<NSWindow*> CocoaTest::WindowsLeft() {
  const std::set<NSWindow*> windows(ApplicationWindows());
  std::set<NSWindow*> windows_left;
  std::set_difference(windows.begin(), windows.end(),
                      initial_windows_.begin(), initial_windows_.end(),
                      std::inserter(windows_left, windows_left.begin()));
  return windows_left;
}

CocoaTestHelperWindow* CocoaTest::test_window() {
  if (!test_window_) {
    test_window_ = [[CocoaTestHelperWindow alloc] init];
    if (base::debug::BeingDebugged()) {
      [test_window_ orderFront:nil];
    } else {
      [test_window_ orderBack:nil];
    }
  }
  return test_window_;
}
