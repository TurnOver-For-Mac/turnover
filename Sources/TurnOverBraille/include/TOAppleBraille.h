// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver's bridge to macOS's own braille display drivers (the ones VoiceOver uses), in
// /System/Library/ScreenReader/BrailleDrivers. Each driver bundle says which displays it handles; this finds
// connected displays, loads the right driver, writes cells and reads keys. Private to Apple, but every display
// VoiceOver supports then works in TurnOver with nothing to set up (6 Oct 2026).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TOAppleBrailleDisplay : NSObject
/// Every display connected now that one of the drivers takes (USB and HID, including HID over Bluetooth).
+ (NSArray<TOAppleBrailleDisplay *> *)detect;
/// What the last `detect` saw: each connected device a driver claims, and whether its driver loaded, for TurnOver's log.
@property (class, readonly) NSString *lastDetectReport;
/// The last `detect` found a device a driver claims, but no driver would load for it (another process, such as
/// VoiceOver's braille server, may hold it).
@property (class, readonly) BOOL lastDetectFoundUnopened;
/// Displays paired with the Mac over Bluetooth whose names a driver lists (asks for Bluetooth permission once).
/// Connecting takes a few seconds, on TurnOver's braille thread; the answer comes back on the main thread.
+ (void)detectBluetoothWithCompletion:(void (^)(TOAppleBrailleDisplay *_Nullable display))completion;
/// What happened on the last Bluetooth look, for TurnOver's log.
@property (class, readonly) NSString *lastBluetoothReport;
@property (readonly) NSString *modelIdentifier;   // "com.apple.scrod.braille.driver.humanware.vario.ultra.20"
@property (readonly) NSString *driverName;        // "BrailleConnect"
@property (readonly) NSInteger cellCount;
@property (readonly) BOOL isLoaded;
/// Connected over Bluetooth (its driver lives on the braille thread).
@property (readonly) BOOL isBluetooth;
/// Cells as ISO 11548-1 bytes (dot n is bit n-1).
- (BOOL)writeCells:(NSData *)cells;
/// Key events since the last call: bit 16 set while pressed, bits 8-15 the key, bits 0-7 its kind
/// (0 routing key, 1 display key, 2 braille keyboard, 3 status routing key).
- (NSArray<NSNumber *> *)readInputEvents;
/// The model's key table: input identifier (pressed) to VoiceOver command ("SCRBraille.panLeft").
@property (readonly) NSDictionary<NSNumber *, NSString *> *keyCommands;
/// The model's chords: "first.second" input identifiers (pressed) to VoiceOver command.
@property (readonly) NSDictionary<NSString *, NSString *> *chordCommands;
- (void)close;
@end

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_BEGIN

/// macOS's braille translation (VoiceOver's: Duxbury, liblouis and Apple's own tables), contracted and
/// uncontracted, both ways.
@interface TOBrailleTranslator : NSObject
/// The tables for a locale ("en_GB"), as identifier and name pairs, the system's defaults first.
+ (NSArray<NSArray<NSString *> *> *)tablesForLocale:(NSString *)localeIdentifier;
/// The system's default contracted table for a locale, or its first default.
+ (nullable NSString *)defaultTableForLocale:(NSString *)localeIdentifier contracted:(BOOL)contracted;
+ (nullable instancetype)translatorForTable:(NSString *)identifier;
@property (readonly) NSString *tableIdentifier;
/// Unicode braille (U+2800 onwards), and for each cell the offset in `text` it came from.
- (NSString *)brailleForText:(NSString *)text locations:(NSArray<NSNumber *> *_Nullable *_Nullable)locations;
/// Braille typed on a display, as text.
- (NSString *)textForBraille:(NSString *)braille;
@end

NS_ASSUME_NONNULL_END
