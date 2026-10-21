// SPDX-License-Identifier: GPL-3.0-or-later
#import "TOAppleBraille.h"
#import <IOKit/IOKitLib.h>
#import <IOBluetooth/IOBluetooth.h>
#import <dlfcn.h>
#import <objc/runtime.h>

/// What a driver is handed for a Bluetooth display: its address and the transport, as VoiceOver's element gives them.
@interface TOBluetoothElement : NSObject <NSCopying>
@property int transport;
@property (copy) NSString *bluetoothAddress;
@property int identifier;
@end
@implementation TOBluetoothElement
- (unsigned int)ioObject { return 0; }
- (BOOL)isBluetoothLowEnergy { return NO; }
- (id)copyWithZone:(NSZone *)zone { TOBluetoothElement *e = [TOBluetoothElement new]; e.transport = _transport; e.bluetoothAddress = _bluetoothAddress; e.identifier = _identifier; return e; }
@end

// The drivers' interface (SCROBrailleDriverProtocol, interface version 4) and the device wrappers they take.
@interface NSObject (TOSCRODriver)
- (instancetype)initWithIOObject:(io_object_t)object;
- (int)loadDriverWithIOElement:(id)element;
- (BOOL)unloadDriver;
- (BOOL)isDriverLoaded;
- (long long)mainSize;
- (BOOL)setMainCells:(const char *)cells length:(long long)length;
- (id)getInputEvents;
- (id)modelIdentifier;
@end

static NSString *const kDrivers = @"/System/Library/ScreenReader/BrailleDrivers";

@implementation TOAppleBrailleDisplay {
    id _driver;
    NSBundle *_bundle;
    NSThread *_thread;   // the driver lives on the braille thread, where its callbacks arrive
    BOOL _bluetooth;
    NSTimer *_poll;      // on the braille thread
    NSData *_pendingCells;   // the latest frame not yet written (guarded by @synchronized(self))
    BOOL _writeScheduled;
}

/// The braille thread: a run loop of its own, as VoiceOver gives its drivers, so a Bluetooth driver's channel
/// callbacks are delivered while it waits for them (on the main thread they never came: runLoopStatus 3).
+ (NSThread *)brailleThread {
    static NSThread *thread;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        thread = [[NSThread alloc] initWithBlock:^{
            [[NSRunLoop currentRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
            while (YES) @autoreleasepool { [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]; }
        }];
        thread.name = @"TurnOver braille";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [thread start];
    });
    return thread;
}

/// Run a block on the display's thread (the braille thread for Bluetooth), waiting for it.
- (void)onThread:(dispatch_block_t)block {
    if (!_thread || [NSThread currentThread] == _thread) { block(); return; }
    [self performSelector:@selector(runBlock:) onThread:_thread withObject:block waitUntilDone:YES];
}
- (void)runBlock:(dispatch_block_t)block { block(); }

+ (void)runBlock:(dispatch_block_t)block { block(); }

+ (void)detectBluetoothWithCompletion:(void (^)(TOAppleBrailleDisplay *))completion {
    dispatch_block_t work = ^{
        TOAppleBrailleDisplay *d = [self detectBluetooth].firstObject;
        if (d) { d->_thread = [self brailleThread]; d->_bluetooth = YES; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(d); });
    };
    [self performSelector:@selector(runBlock:) onThread:[self brailleThread] withObject:work waitUntilDone:NO];
}

+ (void)loadFrameworks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *base = @"/System/Library/PrivateFrameworks/ScreenReader.framework/Versions/A/Frameworks/";
        dlopen([base stringByAppendingString:@"ScreenReaderOutput.framework/ScreenReaderOutput"].UTF8String, RTLD_NOW);
        dlopen([base stringByAppendingString:@"ScreenReaderBrailleDriver.framework/ScreenReaderBrailleDriver"].UTF8String, RTLD_NOW);
        // The drivers take a Bluetooth display only from an element that says it is one (the driver checks
        // conformsToProtocol:, read from the BAUM driver, 6 Oct 2026).
        for (NSString *name in @[@"SCROIOElementProtocol", @"SCROIOBluetoothElementProtocol"]) {
            Protocol *p = objc_getProtocol(name.UTF8String);
            if (p) class_addProtocol([TOBluetoothElement class], p);
        }
    });
}

/// A driver's matching dictionary as IOKit wants it: "*" means any value, so the key is left out. USB matching takes
/// idVendor only together with idProduct, so a vendor-only dictionary (Freedom Scientific's, any product) matched
/// nothing and a Focus 5 by USB was never found (macOS 27, 21 Oct 2026); its properties go through IOPropertyMatch,
/// which compares them as they are. FTDI's vendor (Brailliant's and VarioPro's dictionaries list it alone) is left
/// out: it is a serial chip in countless adapters and boards, which would match, fail to load, and set TurnOver
/// asking VoiceOver's braille server to quit and warning about a display that isn't there (review, 21 Oct 2026).
static const NSInteger kFTDIVendor = 1027;   // 0x0403

static NSMutableDictionary *matching(NSDictionary *autodetect) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    [autodetect enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if ([value isKindOfClass:NSString.class] && [value isEqual:@"*"]) return;
        m[key] = value;
    }];
    if (![m[@"IOProviderClass"] isEqual:@"IOHIDDevice"] && m[@"idVendor"] && !m[@"idProduct"]) {
        if ([m[@"idVendor"] respondsToSelector:@selector(integerValue)] && [m[@"idVendor"] integerValue] == kFTDIVendor) return nil;
        NSMutableDictionary *props = [NSMutableDictionary dictionary];
        for (NSString *key in m.allKeys) if (![key isEqual:@"IOProviderClass"]) { props[key] = m[key]; [m removeObjectForKey:key]; }
        m[@"IOPropertyMatch"] = props;
    }
    return m;
}

static NSNumber *number(io_service_t s, NSString *key) {
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    return v ? (__bridge_transfer NSNumber *)v : nil;
}

static NSMutableString *detectReport;
static BOOL detectFoundUnopened;
+ (NSString *)lastDetectReport { return detectReport ?: @""; }
+ (BOOL)lastDetectFoundUnopened { return detectFoundUnopened; }

+ (NSArray<TOAppleBrailleDisplay *> *)detect {
    [self loadFrameworks];
    detectReport = [NSMutableString string];
    detectFoundUnopened = NO;
    NSMutableSet *unopened = [NSMutableSet set];   // "vendor:product" claimed by a driver that wouldn't load
    NSMutableArray *found = [NSMutableArray array];
    NSMutableSet *taken = [NSMutableSet set];   // "vendor:product" already driven (a display is both a USB and a HID device)
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:kDrivers error:nil] sortedArrayUsingSelector:@selector(compare:)];
    // HID matches first (they carry the keys), then plain USB; within each, matches naming a product before vendor-only ones.
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *name in names) {
        if (![name hasSuffix:@".brailledriver"]) continue;
        NSString *path = [kDrivers stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        for (NSDictionary *d in info[@"BrailleDriverAutoDetectDictionaries"] ?: @[]) {
            NSString *cls = d[@"IOProviderClass"];
            if (![cls isEqual:@"IOHIDDevice"] && ![cls isEqual:@"IOUSBDevice"] && ![cls isEqual:@"IOUSBHostDevice"]) continue;
            BOOL specific = (d[@"idProduct"] && ![d[@"idProduct"] isEqual:@"*"]) || (d[@"ProductID"] && ![d[@"ProductID"] isEqual:@"*"]);
            NSInteger rank = ([cls isEqual:@"IOHIDDevice"] ? 0 : 2) + (specific ? 0 : 1);
            [candidates addObject:@{@"rank": @(rank), @"path": path, @"match": d}];
        }
    }
    [candidates sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"rank" ascending:YES]]];
    for (NSDictionary *c in candidates) {
        NSDictionary *d = c[@"match"];
        BOOL hid = [d[@"IOProviderClass"] isEqual:@"IOHIDDevice"];
        io_iterator_t it = 0;
        NSMutableDictionary *m = matching(d);
        if (!m) continue;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)m, &it) != KERN_SUCCESS) continue;
        io_service_t s;
        while ((s = IOIteratorNext(it))) {
            NSNumber *v = number(s, hid ? @"VendorID" : @"idVendor"), *p = number(s, hid ? @"ProductID" : @"idProduct");
            NSString *key = [NSString stringWithFormat:@"%@:%@", v, p];
            if (![taken containsObject:key]) {
                // Loaded on the braille thread, and driven there from now on: a USB driver waits for each answer
                // by running the run loop of the thread it is called on, and polled from the main thread every
                // 30 ms it held that thread 70% of the time, so speech after a key came 100 to 200 ms late (a
                // Focus 5, 21 Oct 2026).
                __block TOAppleBrailleDisplay *display = nil;
                NSString *bundlePath = c[@"path"];
                dispatch_block_t load = ^{
                    display = [[self alloc] initWithService:s hid:hid bundlePath:bundlePath];
                    if (display) display->_thread = [self brailleThread];
                };
                if ([NSThread currentThread] == [self brailleThread]) load();
                else [self performSelector:@selector(runBlock:) onThread:[self brailleThread] withObject:load waitUntilDone:YES];
                [detectReport appendFormat:@" %@ %@ (%@): %@;", [[c[@"path"] lastPathComponent] stringByDeletingPathExtension],
                    key, d[@"IOProviderClass"], display ? [NSString stringWithFormat:@"loaded, %ld cells", (long)display.cellCount] : @"would not load"];
                if (display) { [found addObject:display]; [taken addObject:key]; [unopened removeObject:key]; }
                else [unopened addObject:key];
            }
            IOObjectRelease(s);
        }
        IOObjectRelease(it);
    }
    detectFoundUnopened = unopened.count > 0;
    return found;
}

static NSMutableString *btReport;
+ (NSString *)lastBluetoothReport { return btReport ?: @""; }

+ (NSArray<TOAppleBrailleDisplay *> *)detectBluetooth {
    [self loadFrameworks];
    btReport = [NSMutableString string];
    NSMutableArray *found = [NSMutableArray array];
    NSArray *paired = [IOBluetoothDevice pairedDevices] ?: @[];
    [btReport appendFormat:@"%lu paired:", (unsigned long)paired.count];
    for (IOBluetoothDevice *d in paired) [btReport appendFormat:@" \"%@\"%@;", d.name, d.isConnected ? @" (connected)" : @""];
    if (paired.count == 0) return found;
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:kDrivers error:nil] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        if (![name hasSuffix:@".brailledriver"]) continue;
        NSString *path = [kDrivers stringByAppendingPathComponent:name];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
        NSArray *patterns = info[@"BrailleDriverBluetoothSearchDictionary"][@"BrailleDriverBluetoothDeviceNameRegexPatterns"];
        for (IOBluetoothDevice *d in [paired sortedArrayUsingComparator:^NSComparisonResult(IOBluetoothDevice *a, IOBluetoothDevice *b) {
                 return a.isConnected == b.isConnected ? NSOrderedSame : (a.isConnected ? NSOrderedAscending : NSOrderedDescending); }]) {
            if (found.count) break;
            // Not phones, headphones or game controllers: BrailleSense's driver matches any name with "Sense" in it,
            // DualSense controllers included, and each try held the search up.
            BluetoothDeviceClassMajor major = d.deviceClassMajor;
            if (major == kBluetoothDeviceClassMajorPhone || major == kBluetoothDeviceClassMajorAudio || major == kBluetoothDeviceClassMajorPeripheral) continue;
            BOOL matches = NO;
            for (NSString *p in patterns ?: @[]) {
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^(%@)$", p] options:0 error:nil];
                if (d.name && [re firstMatchInString:d.name options:0 range:NSMakeRange(0, d.name.length)]) { matches = YES; break; }
            }
            if (!matches) continue;
            NSLog(@"TurnOver braille: paired display %@ (%@) matches %@", d.name, d.addressString, name);
            // The display takes ten seconds or so to answer when it is idle, longer than the driver waits for its
            // channel (5 s): open the link first, so the driver's channel opens at once.
            if (!d.isConnected) {
                IOReturn r = [d openConnection];
                [btReport appendFormat:@" link %@: %d;", d.name, r];
            }
            // Transport 2 is Bluetooth in the drivers (1 USB, 4 HID; read from the BAUM driver, 6 Oct 2026). Loading
            // over Bluetooth answers at once and connects in the background, so wait for the connection.
            for (NSNumber *t in @[@2]) {
                for (NSString *addr in @[d.addressString ?: @""]) {
                    TOBluetoothElement *e = [TOBluetoothElement new];
                    e.transport = t.intValue; e.bluetoothAddress = addr;
                    TOAppleBrailleDisplay *display = [[self alloc] initWithElement:e bundlePath:path wait:8];
                    [btReport appendFormat:@" %@ transport %@ %@: %@;", name, t, addr, display ? @"loaded" : @"no"];
                    if (display) { [found addObject:display]; goto next; }
                }
            }
            next:;
        }
    }
    return found;
}

- (nullable instancetype)initWithService:(io_service_t)service hid:(BOOL)hid bundlePath:(NSString *)path {
    Class elementClass = NSClassFromString(hid ? @"SCROIOHIDElement" : @"SCROIOUSBElement");
    if (!elementClass) return nil;
    return [self initWithElement:[[elementClass alloc] initWithIOObject:service] bundlePath:path];
}

- (nullable instancetype)initWithElement:(id)element bundlePath:(NSString *)path {
    return [self initWithElement:element bundlePath:path wait:0];
}

- (nullable instancetype)initWithElement:(id)element bundlePath:(NSString *)path wait:(NSTimeInterval)wait {
    if (!(self = [super init])) return nil;
    _bundle = [NSBundle bundleWithPath:path];
    if (![_bundle load] || ![_bundle principalClass]) return nil;
    id driver = [[[_bundle principalClass] alloc] init];
    if (!element || !driver || ![driver respondsToSelector:@selector(loadDriverWithIOElement:)]) return nil;
    int r = [driver loadDriverWithIOElement:element];
    if (wait > 0) {
        // A connection still opening: give it time, letting its callbacks run.
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:wait];
        while ([end timeIntervalSinceNow] > 0 && !([driver isDriverLoaded] && [driver mainSize] > 0)) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        [btReport appendFormat:@" load answered %d, then loaded %d with %lld cells;", r, [driver isDriverLoaded], [driver mainSize]];
        if (!([driver isDriverLoaded] && [driver mainSize] > 0)) { [driver unloadDriver]; return nil; }
    } else if (r != 0 || [driver mainSize] <= 0) return nil;
    _driver = driver;
    _driverName = [[path lastPathComponent] stringByDeletingPathExtension];
    _modelIdentifier = [[driver modelIdentifier] description] ?: @"";
    _cellCount = (NSInteger)[driver mainSize];
    // The model's key table, beside the driver's code.
    NSMutableDictionary *keys = [NSMutableDictionary dictionary];
    NSString *table = [_bundle pathForResource:_modelIdentifier ofType:@"plist"];
    NSMutableDictionary *chords = [NSMutableDictionary dictionary];
    for (NSDictionary *e in (table ? [NSArray arrayWithContentsOfFile:table] : nil) ?: @[]) {
        id raw = e[@"SCRBrailleInputIdentifier"];
        if (!e[@"SCRCommand"] || !raw) continue;
        // A chord is two identifiers joined by a dot ("65793.68097", rocker down with a selector key): read whole, it
        // came out as its first key and overwrote that key's own command (the Focus 40's table, 21 Oct 2026).
        NSString *text = [raw description];
        if ([text containsString:@"."]) { chords[text] = e[@"SCRCommand"]; continue; }
        NSNumber *ident = @([raw integerValue]);
        keys[ident] = e[@"SCRCommand"];
    }
    _chordCommands = chords;
    _keyCommands = keys;
    return self;
}


- (BOOL)writeCells:(NSData *)cells {
    if (!_driver) return NO;
    NSMutableData *d = [cells mutableCopy];
    if ((NSInteger)d.length < _cellCount) [d increaseLengthBy:_cellCount - d.length];
    __block BOOL ok = NO;
    id driver = _driver; NSInteger n = _cellCount;
    [self onThread:^{ ok = [driver setMainCells:d.bytes length:n]; }];
    return ok;
}

- (NSArray<NSNumber *> *)readInputEvents {
    if (!_driver) return @[];
    __block id events = nil;
    id driver = _driver;
    [self onThread:^{ events = [driver getInputEvents]; }];
    return [events isKindOfClass:NSArray.class] ? events : @[];
}

- (BOOL)isBluetooth { return _bluetooth; }

- (void)writeCellsAsync:(NSData *)cells completion:(void (^)(BOOL))completion {
    if (!_driver) { completion(NO); return; }
    NSMutableData *d = [cells mutableCopy];
    if ((NSInteger)d.length < _cellCount) [d increaseLengthBy:_cellCount - d.length];
    BOOL schedule;
    @synchronized (self) { _pendingCells = d; schedule = !_writeScheduled; _writeScheduled = YES; }
    if (!schedule) return;   // the write already on its way takes this frame
    id driver = _driver; NSInteger n = _cellCount;
    // The write stays marked under way until the driver has returned: a USB driver waits by running this thread's
    // run loop, and a second write scheduled meanwhile entered setMainCells: inside the first (code review,
    // 21 Oct 2026). Frames that came in during a write are drained here, the latest only.
    dispatch_block_t write = ^{
        for (;;) {
            NSData *frame;
            @synchronized (self) {
                frame = self->_pendingCells; self->_pendingCells = nil;
                if (!frame || !self->_driver) { self->_writeScheduled = NO; return; }   // done, or closed meanwhile
            }
            BOOL ok = [driver setMainCells:frame.bytes length:n];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
        }
    };
    if (!_thread) { write(); return; }
    [self performSelector:@selector(runBlock:) onThread:_thread withObject:write waitUntilDone:NO];
}

- (void)startPollingWithHandler:(void (^)(NSArray<NSNumber *> *, BOOL))handler {
    id driver = _driver;
    if (!driver || !_thread) return;
    __weak TOAppleBrailleDisplay *weakSelf = self;
    [self performSelector:@selector(runBlock:) onThread:_thread withObject:^{
        TOAppleBrailleDisplay *me = weakSelf;
        if (!me) return;
        [me->_poll invalidate];
        __block NSInteger checks = 0;
        me->_poll = [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *timer) {
            id events = [driver getInputEvents];
            NSArray *list = [events isKindOfClass:NSArray.class] ? events : @[];
            BOOL loaded = (++checks % 33 != 0) || [driver isDriverLoaded];
            if (list.count == 0 && loaded) return;
            if (!loaded) [timer invalidate];
            dispatch_async(dispatch_get_main_queue(), ^{ handler(list, loaded); });
        }];
    } waitUntilDone:NO];
}

- (BOOL)isLoaded {
    if (!_driver) return NO;
    __block BOOL loaded = NO;
    id driver = _driver;
    [self onThread:^{ loaded = [driver isDriverLoaded]; }];
    return loaded;
}

- (void)close {
    if (!_driver) return;
    id driver = _driver; NSInteger n = _cellCount;
    _driver = nil;
    [self onThread:^{
        [self->_poll invalidate]; self->_poll = nil;
        char blank[256] = {0};
        [driver setMainCells:blank length:MIN(n, 256)];
        [driver unloadDriver];
    }];
}

- (void)dealloc { [self close]; }
@end

@interface NSObject (TOBRLT)
+ (id)tableEnumeratorWithSystemBundlePath;
+ (id)defaultTablesArrayForLocale:(id)locale;
- (id)translatorBundles;
- (id)tablesForLocale:(id)locale inBundle:(id)bundle;
- (id)localizedName;
- (BOOL)supportsTranslationModeContracted;
- (id)initWithTable:(id)table;
- (id)brailleForText:(id)text locations:(id *)locations;
- (id)textForBraille:(id)braille locations:(id *)locations;
@end

@implementation TOBrailleTranslator {
    id _translator;
}

+ (void)loadFramework {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/ScreenReader.framework/Versions/A/Frameworks/BrailleTranslation.framework/BrailleTranslation", RTLD_NOW);
    });
}

/// Every table for a locale: the defaults, then each translator bundle's (Duxbury, liblouis and so on).
+ (NSArray *)tableObjectsForLocale:(NSString *)localeIdentifier {
    [self loadFramework];
    Class E = NSClassFromString(@"BRLTTableEnumerator");
    if (!E) return @[];
    NSLocale *locale = [NSLocale localeWithLocaleIdentifier:localeIdentifier];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *all = [NSMutableArray arrayWithArray:[E defaultTablesArrayForLocale:locale] ?: @[]];
    id en = [E tableEnumeratorWithSystemBundlePath];
    for (id b in [en translatorBundles] ?: @[]) [all addObjectsFromArray:[en tablesForLocale:locale inBundle:b] ?: @[]];
    for (id t in all) {
        NSString *ident = [[t valueForKey:@"identifier"] description];
        if (ident && ![seen containsObject:ident]) { [seen addObject:ident]; [out addObject:t]; }
    }
    return out;
}

+ (NSArray<NSArray<NSString *> *> *)tablesForLocale:(NSString *)localeIdentifier {
    NSMutableArray *out = [NSMutableArray array];
    for (id t in [self tableObjectsForLocale:localeIdentifier]) [out addObject:@[[[t valueForKey:@"identifier"] description], [[t localizedName] description] ?: @""]];
    return out;
}

+ (nullable NSString *)defaultTableForLocale:(NSString *)localeIdentifier contracted:(BOOL)contracted {
    [self loadFramework];
    Class E = NSClassFromString(@"BRLTTableEnumerator");
    NSArray *defaults = [E defaultTablesArrayForLocale:[NSLocale localeWithLocaleIdentifier:localeIdentifier]] ?: @[];
    for (id t in defaults) if ([t supportsTranslationModeContracted] == contracted) return [[t valueForKey:@"identifier"] description];
    return [[defaults.firstObject valueForKey:@"identifier"] description];
}

+ (nullable instancetype)translatorForTable:(NSString *)identifier {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (cache[identifier]) return cache[identifier];
    // The table may belong to any locale; look through the user's languages and English.
    NSMutableArray *locales = [NSMutableArray arrayWithArray:NSLocale.preferredLanguages];
    [locales addObjectsFromArray:@[NSLocale.currentLocale.localeIdentifier, @"en_GB", @"en_US"]];
    NSString *lang = [[identifier componentsSeparatedByString:@"."].lastObject componentsSeparatedByString:@"-"].firstObject;
    if (lang.length) [locales addObject:lang];
    for (NSString *l in locales) {
        for (id t in [self tableObjectsForLocale:[l stringByReplacingOccurrencesOfString:@"-" withString:@"_"]]) {
            if (![[[t valueForKey:@"identifier"] description] isEqual:identifier]) continue;
            id tr = [[NSClassFromString(@"BRLTServiceTranslator") alloc] initWithTable:t];
            if (!tr) return nil;
            TOBrailleTranslator *me = [[self alloc] init];
            me->_translator = tr;
            me->_tableIdentifier = identifier;
            cache[identifier] = me;
            return me;
        }
    }
    return nil;
}

- (NSString *)brailleForText:(NSString *)text locations:(NSArray<NSNumber *> **)locations {
    id loc = nil;
    id out = [_translator brailleForText:text locations:&loc];
    if (locations) *locations = [loc isKindOfClass:NSArray.class] ? loc : nil;
    return [out isKindOfClass:NSString.class] ? out : @"";
}

- (NSString *)textForBraille:(NSString *)braille {
    id loc = nil;
    id out = [_translator textForBraille:braille locations:&loc];
    return [out isKindOfClass:NSString.class] ? out : @"";
}
@end
