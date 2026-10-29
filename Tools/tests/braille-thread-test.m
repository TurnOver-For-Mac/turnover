// SPDX-License-Identifier: GPL-3.0-or-later
// Fake drivers exercise the real bridge without opening a display, permissions or private frameworks. Gates
// hold an exact driver phase while pumping its run loop; assertions never depend on how quickly a timer fires.
#import <Foundation/Foundation.h>
#import "TOAppleBraille.h"
#import <unistd.h>

static void check(BOOL ok, NSString *name) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", name.UTF8String); exit(1); }
}
static void waitFor(dispatch_semaphore_t signal) {
    check(dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0,
          @"driver reached the requested phase within two seconds");
}
static void runUntil(BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!done() && end.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
    }
    check(done(), @"main received the expected callback within two seconds");
}

@interface TOAppleBrailleDisplay (ThreadTest)
+ (NSThread *)brailleThread;
- (void)runBlock:(dispatch_block_t)block;
@end

@interface DriverGate : NSObject
@property (readonly) dispatch_semaphore_t entered;
- (void)enterAndWait;
- (void)open;
@end
@implementation DriverGate {
    dispatch_semaphore_t _proceed;
}
- (instancetype)init {
    if ((self = [super init])) { _entered = dispatch_semaphore_create(0); _proceed = dispatch_semaphore_create(0); }
    return self;
}
- (void)enterAndWait {
    dispatch_semaphore_signal(_entered);
    while (dispatch_semaphore_wait(_proceed, DISPATCH_TIME_NOW) != 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
}
- (void)open { dispatch_semaphore_signal(_proceed); }
@end

@interface WaitingDriver : NSObject
@property NSInteger depth, maxDepth, callsAfterUnload, wrongThreadCalls, writeCalls, blankCalls, unloadCalls;
@property BOOL unloaded, unloadSucceeds;
@property (strong) NSMutableArray<NSNumber *> *frames;
@property (strong) DriverGate *writeGate, *readGate, *blankGate, *unloadGate;
@property (copy) dispatch_block_t duringWrite, duringRead;
- (void)runNested:(dispatch_block_t)work;
@end
@implementation WaitingDriver
- (instancetype)init {
    if ((self = [super init])) { _frames = [NSMutableArray array]; _unloadSucceeds = YES; }
    return self;
}
- (void)enter {
    if ([NSThread currentThread] != [TOAppleBrailleDisplay brailleThread]) _wrongThreadCalls++;
    if (_unloaded) _callsAfterUnload++;
    _depth++; _maxDepth = MAX(_maxDepth, _depth);
}
- (void)runBlock:(dispatch_block_t)work { work(); }
- (void)runNested:(dispatch_block_t)work {
    __block BOOL finished = NO;
    [self performSelector:@selector(runBlock:) onThread:[NSThread currentThread] withObject:^{ work(); finished = YES; } waitUntilDone:NO];
    while (!finished)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
- (BOOL)setMainCells:(const char *)cells length:(long long)length {
    [self enter];
    DriverGate *gate;
    if (length && cells[0]) {
        _writeCalls++; [_frames addObject:@((unsigned char)cells[0])];
        gate = _writeGate; _writeGate = nil;
        dispatch_block_t work = _duringWrite; _duringWrite = nil;
        if (work) [self runNested:work];
    } else { _blankCalls++; gate = _blankGate; _blankGate = nil; }
    if (gate) [gate enterAndWait];
    _depth--; return YES;
}
- (id)getInputEvents {
    [self enter];
    dispatch_block_t work = _duringRead; _duringRead = nil;
    if (work) [self runNested:work];
    DriverGate *gate = _readGate; _readGate = nil;
    if (gate) [gate enterAndWait];
    _depth--; return @[];
}
- (BOOL)isDriverLoaded { [self enter]; BOOL loaded = !_unloaded; _depth--; return loaded; }
- (BOOL)unloadDriver {
    [self enter]; _unloadCalls++;
    DriverGate *gate = _unloadGate; _unloadGate = nil;
    if (gate) [gate enterAndWait];
    if (_unloadSucceeds) _unloaded = YES;
    _depth--; return _unloadSucceeds;
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
static void checkClosed(TOAppleBrailleDisplay *display, WaitingDriver *driver) {
    check(driver.unloaded && driver.depth == 0, @"release completes after unload returns");
    check(driver.unloadCalls == 1 && driver.blankCalls == 1, @"one blank and one unload per release");
    check(driver.maxDepth == 1 && driver.wrongThreadCalls == 0, @"driver calls stay on their thread and never nest");
    check(display.releaseState == TOBrailleReleaseStateReleased, @"successful unload is released");
    check(!display.isLoaded, @"closed display is not loaded");
    __block BOOL rejected = NO;
    [display writeCellsAsync:frame(9) completion:^(BOOL ok) { check(!ok, @"write after close is rejected"); rejected = YES; }];
    [display close]; runUntil(^BOOL { return rejected; });
    check(driver.callsAfterUnload == 0, @"no driver calls after unload");
}

static void checkPendingPhase(NSString *phase) {
    WaitingDriver *driver = [WaitingDriver new];
    TOAppleBrailleDisplay *display = displayFor(driver);
    DriverGate *gate = [DriverGate new];
    if ([phase isEqual:@"write"]) { driver.writeGate = gate; send(display, 1); }
    else if ([phase isEqual:@"poll"]) {
        driver.readGate = gate;
        [display startPollingWithHandler:^(NSArray *events, BOOL loaded) {}];
    } else if ([phase isEqual:@"blank"]) driver.blankGate = gate;
    else driver.unloadGate = gate;

    if ([phase isEqual:@"write"] || [phase isEqual:@"poll"]) waitFor(gate.entered);
    __block NSInteger completions = 0;
    void (^completed)(TOBrailleReleaseState) = ^(TOBrailleReleaseState state) {
        check([NSThread isMainThread], @"release completion runs on main");
        check(state == TOBrailleReleaseStateReleased, @"successful close reports released");
        completions++;
    };
    [display closeWithCompletion:completed];
    if ([phase isEqual:@"blank"] || [phase isEqual:@"unload"]) waitFor(gate.entered);
    [display closeWithCompletion:completed];
    check(display.releaseState == TOBrailleReleaseStatePending, @"held driver phase keeps release pending");

    __block BOOL mainRan = NO, rejected = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ mainRan = YES; });
    [display writeCellsAsync:frame(9) completion:^(BOOL ok) { check(!ok, @"pending release rejects new writes"); rejected = YES; }];
    runUntil(^BOOL { return mainRan && rejected; });
    check(completions == 0, @"main remains responsive without claiming the held display was released");

    // The legacy caller still waits for the same attempt; it does not start another blank/unload.
    dispatch_semaphore_t legacyStarted = dispatch_semaphore_create(0), legacyFinished = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        dispatch_semaphore_signal(legacyStarted); [display close]; dispatch_semaphore_signal(legacyFinished);
    });
    waitFor(legacyStarted);
    check(dispatch_semaphore_wait(legacyFinished, DISPATCH_TIME_NOW) != 0, @"legacy close cannot return while the driver phase is held");
    [gate open];
    runUntil(^BOOL { return completions == 2; });
    waitFor(legacyFinished);
    checkClosed(display, driver);
    [display closeWithCompletion:completed];
    runUntil(^BOOL { return completions == 3; });
    check(driver.unloadCalls == 1, @"repeated completed close does not unload again");
}

int main(void) { @autoreleasepool {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        fputs("FAIL: braille thread test timed out\n", stderr); _exit(1);
    });

    WaitingDriver *driver = [WaitingDriver new];
    TOAppleBrailleDisplay *display = displayFor(driver);
    check(display.releaseState == TOBrailleReleaseStateOpen, @"display starts open");
    __weak TOAppleBrailleDisplay *weakDisplay = display;
    __block BOOL wrote3 = NO, wrote5 = NO;
    [display startPollingWithHandler:^(NSArray *events, BOOL loaded) {}];
    // Establish that the timer is installed before firing it reentrantly inside a write, without sleeping.
    [display performSelector:@selector(runBlock:) onThread:[TOAppleBrailleDisplay brailleThread] withObject:^{} waitUntilDone:YES];
    driver.duringWrite = ^{
        [[weakDisplay valueForKey:@"poll"] fire];
        send(weakDisplay, 2);
        [weakDisplay writeCellsAsync:frame(3) completion:^(BOOL ok) { check(ok, @"latest write accepted"); wrote3 = YES; }];
    };
    send(display, 1); runUntil(^BOOL { return wrote3; });
    // Stop the timer before setting the read hook: this read is explicitly requested, so it cannot race a poll.
    [display performSelector:@selector(runBlock:) onThread:[TOAppleBrailleDisplay brailleThread] withObject:^{ [[weakDisplay valueForKey:@"poll"] invalidate]; } waitUntilDone:YES];
    driver.duringRead = ^{
        send(weakDisplay, 4);
        [weakDisplay writeCellsAsync:frame(5) completion:^(BOOL ok) { check(ok, @"latest read-time write accepted"); wrote5 = YES; }];
    };
    [display readInputEvents]; runUntil(^BOOL { return wrote5; });
    [display close];
    check([driver.frames isEqual:@[@1, @3, @5]], @"latest frames survive nested write and poll callbacks");
    checkClosed(display, driver);

    for (NSString *phase in @[@"poll", @"write", @"blank", @"unload"]) checkPendingPhase(phase);

    // A failed unload stays owned after all caller references go away. It is never retried or presented as free.
    __weak TOAppleBrailleDisplay *failedDisplay;
    __weak WaitingDriver *failedDriver;
    @autoreleasepool {
        WaitingDriver *failure = [WaitingDriver new]; failure.unloadSucceeds = NO;
        TOAppleBrailleDisplay *failed = displayFor(failure);
        failedDisplay = failed; failedDriver = failure;
        __block BOOL completed = NO;
        [failed closeWithCompletion:^(TOBrailleReleaseState state) {
            check([NSThread isMainThread] && state == TOBrailleReleaseStateFailed, @"unsuccessful unload reports failed on main");
            completed = YES;
        }];
        runUntil(^BOOL { return completed; });
        [failed close];
    }
    check(failedDisplay != nil && failedDriver != nil, @"failed session retains display and driver ownership");
    check(failedDisplay.releaseState == TOBrailleReleaseStateFailed, @"failed release remains unconfirmed");
    __block BOOL repeatedFailure = NO, rejectedFailure = NO;
    [failedDisplay closeWithCompletion:^(TOBrailleReleaseState state) { check(state == TOBrailleReleaseStateFailed, @"repeated failed close remains failed"); repeatedFailure = YES; }];
    [failedDisplay writeCellsAsync:frame(9) completion:^(BOOL ok) { check(!ok, @"failed session rejects writes"); rejectedFailure = YES; }];
    runUntil(^BOOL { return repeatedFailure && rejectedFailure; });
    check(!failedDriver.unloaded && failedDriver.unloadCalls == 1 && failedDriver.writeCalls == 0,
          @"failed driver is neither discarded nor called again");
    check(failedDriver.maxDepth == 1 && failedDriver.wrongThreadCalls == 0, @"failed unload preserves driver ownership thread");

    WaitingDriver *orphan = [WaitingDriver new];
    @autoreleasepool { TOAppleBrailleDisplay *unused = displayFor(orphan); (void)unused; }
    check(orphan.unloaded && orphan.maxDepth == 1 && orphan.wrongThreadCalls == 0, @"last owner releases an idle display on its thread");
    puts("braille thread tests: all passed");
} return 0; }
