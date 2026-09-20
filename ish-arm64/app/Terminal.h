//
//  Terminal.h
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

struct tty;

@interface Terminal : NSObject

+ (Terminal *)terminalWithType:(int)type number:(int)number;
#if !ISH_LINUX
// Returns a strong struct tty and a Terminal that has a weak reference to the same tty
+ (Terminal *)createPseudoTerminal:(struct tty **)tty;
#endif

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *uuid;

+ (void)convertCommand:(NSArray<NSString *> *)command toArgs:(char *)argv limitSize:(size_t)maxSize;

- (int)sendOutput:(const void *)buf length:(int)len;
- (void)sendInput:(NSData *)input;
- (NSString *)arrow:(char)direction;

// Make this terminal no longer be the singleton terminal with its type and number. Will happen eventually if all references go away, but sometimes you want it to happen now.
- (void)destroy;

@property (readonly) WKWebView *webView;
@property (nonatomic) BOOL enableVoiceOverAnnounce;
// Use KVO on this
@property (readonly) BOOL loaded;

/// Posted the first time this terminal's output enters the alternate screen.
///
/// That is the moment a full-screen application (this app's harness TUI) takes
/// the terminal over and is about to paint its own frame, which is what the
/// launch screen waits for -- otherwise the user watches the shell's loading
/// text as a startup stage of its own, with nothing to do but look at it.
extern NSNotificationName const DSHTerminalDidEnterAlternateScreenNotification;

/// Posted when a full-screen application gives the terminal back.
///
/// The harness exits cleanly from time to time and the app answers a finished
/// session with a fresh shell, which then spends half a minute loading. That
/// window has no interactive program in it, so the app covers it: this is the
/// signal that the cover is needed, and an enter notification is the signal that
/// it can come down.
extern NSNotificationName const DSHTerminalDidLeaveAlternateScreenNotification;

@end

extern struct tty_driver ios_console_driver;
