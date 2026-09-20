//
//  DSHModelForwarder.h
//  DSH
//
//  Loopback reverse proxy for model traffic.
//
//  Why this exists: inside the app the Linux guest's sockets are passed through
//  to the host, but iOS refuses the host's own outbound connects on some
//  systems (the guest sees EHOSTUNREACH for every non-loopback address while
//  loopback keeps working). The host app itself reaches the network fine, so
//  the guest sends its model requests here instead: it talks plain HTTP to
//  127.0.0.1 and this class forwards them upstream with NSURLSession.
//
//  The guest is pointed at it with DEEPSEEK_BASE_URL (see guestEnvironment),
//  which dsh already honours — the upstream test suite drives dsh the same way.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the listener comes back on a different port than before.
///
/// The guest is told one base URL and keeps using it, so a port change has to
/// reach it: whoever owns the guest environment file must rewrite it. Without
/// this, a re-arm on a new port is indistinguishable from a dead listener --
/// which is exactly how "retrying model request" became permanent on device.
extern NSNotificationName const DSHModelForwarderPortDidChangeNotification;

@interface DSHModelForwarder : NSObject

+ (instancetype)shared;

/// Defaults to https://api.deepseek.com; override with DSH_FORWARD_UPSTREAM.
@property (nonatomic, readonly) NSString *upstream;

/// YES once the loopback listener is up.
@property (nonatomic, readonly) BOOL running;

/// http://127.0.0.1:<port>, or nil while stopped.
@property (nonatomic, readonly, nullable) NSString *baseURLString;

- (BOOL)start;
/// Stop and start again on the same port; call when the app returns to the foreground.
- (void)restart;
/// Re-arm only if the listener is actually gone, and say why in the app log.
///
/// This is the method callers should use. `restart` closes a listener that may
/// be perfectly healthy and carrying a request, so it is left for explicit
/// recovery; `ensureListening` is idempotent and safe to call from every
/// lifecycle hook and from the watchdog.
- (void)ensureListening;
- (void)stop;

/// Environment for dsh-serve (empty while stopped).
- (NSDictionary<NSString *, NSString *> *)guestEnvironment;

@end

NS_ASSUME_NONNULL_END
