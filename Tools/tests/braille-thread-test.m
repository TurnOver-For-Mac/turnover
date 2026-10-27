// SPDX-License-Identifier: GPL-3.0-or-later
// A fake Apple driver which waits by running its run loop, as the USB and Bluetooth drivers do. No display,
// permissions or private frameworks are used. Exercise the real bridge, including selectors arriving mid-call.
#import <Foundation/Foundation.h>
#import "TOAppleBraille.h"
#import <unistd.h>

@interface TOAppleBrailleDisplay (ThreadTest)
+ (NSThread *)brailleThread;
@end

@interface WaitingDriver : NSObject
@property NSInteger depth, maxDepth, callsAfterUnload;
@property BOOL unloaded;
@property (strong) NSMutableArray<NSNumber *> *frames;
@property (copy) dispatch_block_t duringWrite, duringRead;
@end
@implementation WaitingDriver
- (instancetype)init { if ((self = [super init])) _frames = [NSMutableArray array]; return self; }
- (void)enter {
    if (_unloaded) _callsAfterUnload++;
    _depth++; _maxDepth = MAX(_maxDepth, _depth);
}
- (void)wait {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:0.08];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
- (BOOL)setMainCells:(const char *)cells length:(long long)length {
    [self enter];
    if (length && cells[0]) [_frames addObject:@((unsigned char)cells[0])];
    dispatch_block_t work = _duringWrite; _duringWrite = nil;
    if (work) work();
    [self wait]; _depth--; return YES;
}
- (id)getInputEvents {
    [self enter];
    dispatch_block_t work = _duringRead; _duringRead = nil;
    if (work) work();
    [self wait]; _depth--; return @[];
}
- (BOOL)isDriverLoaded { [self enter]; BOOL loaded = !_unloaded; _depth--; return loaded; }
- (BOOL)unloadDriver {
    [self enter]; [self wait]; _unloaded = YES; _depth--; return YES;
}
@end

static TOAppleBrailleDisplay *displayFor(WaitingDriver *driver) {
    TOAppleBrailleDisplay *display = [TOAppleBrailleDisplay new];
    // Test-only injection; production construction still goes through the actual display detection paths.
    [display setValue:driver forKey:@"driver"];
    [display setValue:[TOAppleBrailleDisplay brailleThread] forKey:@"thread"];
    [display setValue:@1 forKey:@"cellCount"];
    return display;
}
static NSData *frame(uint8_t cell) { return [NSData dataWithBytes:&cell length:1]; }
static void send(TOAppleBrailleDisplay *display, uint8_t cell) {
    [display writeCellsAsync:frame(cell) completion:^(BOOL ok) {}];
}
static void spin(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:end];
}
static void check(BOOL ok, NSString *name) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
}
static void waitFor(dispatch_semaphore_t entered) {
    check(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
          @"driver call started within two seconds");
}
static void checkClosed(TOAppleBrailleDisplay *display, WaitingDriver *driver) {
    check(driver.unloaded && driver.depth == 0, @"close waits for unload to return");
    check(driver.maxDepth == 1, @"driver calls never nest");
    check(!display.isLoaded, @"closed display is not loaded");
    send(display, 9); [display close]; spin(0.05);
    check(driver.callsAfterUnload == 0, @"no driver calls after unload");
}
int main(void) { @autoreleasepool {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        fputs("FAIL: braille thread test timed out\n", stderr); _exit(1);
    });
    // A timer fires inside a write; then two writes arrive inside a poll. Only the latest pending frame is kept.
    WaitingDriver *driver = [WaitingDriver new];
    TOAppleBrailleDisplay *display = displayFor(driver);
    __weak TOAppleBrailleDisplay *weakDisplay = display;
    driver.duringWrite = ^{ send(weakDisplay, 2); send(weakDisplay, 3); };
    driver.duringRead = ^{ send(weakDisplay, 4); send(weakDisplay, 5); };
    [display startPollingWithHandler:^(NSArray *events, BOOL loaded) {}];
    send(display, 1); spin(0.6); [display close];
    check([driver.frames isEqual:@[@1, @3, @5]], @"latest frames survive a write and a poll");
    checkClosed(display, driver);

    // Close is delivered by the nested run loop inside each kind of driver call. It must not return early.
    for (NSNumber *poll in @[@NO, @YES]) {
        WaitingDriver *closingDriver = [WaitingDriver new];
        TOAppleBrailleDisplay *closingDisplay = displayFor(closingDriver);
        dispatch_semaphore_t entered = dispatch_semaphore_create(0);
        dispatch_block_t signal = ^{ dispatch_semaphore_signal(entered); };
        if (poll.boolValue) {
            closingDriver.duringRead = signal;
            [closingDisplay startPollingWithHandler:^(NSArray *events, BOOL loaded) {}];
        } else {
            closingDriver.duringWrite = signal;
            send(closingDisplay, 1);
        }
        waitFor(entered);
        [closingDisplay close];
        checkClosed(closingDisplay, closingDriver);
    }
    // Letting the final owner go also unloads an idle display, without retaining self during deallocation.
    WaitingDriver *orphan = [WaitingDriver new];
    @autoreleasepool {
        TOAppleBrailleDisplay *unused = displayFor(orphan);
        (void)unused;
    }
    check(orphan.unloaded && orphan.maxDepth == 1, @"last owner releases an idle display on its thread");
    puts("braille thread tests: all passed");
} return 0; }
