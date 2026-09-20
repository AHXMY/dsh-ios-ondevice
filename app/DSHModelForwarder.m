//
//  DSHModelForwarder.m
//  DSH
//
//  A loopback reverse proxy from the guest to the real model endpoint, because
//  iOS refuses the guest's own outbound connects: the emulator's socket bridge
//  reaches loopback and nothing else. dsh reaches the model through
//  DEEPSEEK_BASE_URL=http://127.0.0.1:<port> and this forwards it.
//
//  Two bugs lived in the first version of this file, and on the device they
//  showed up as "retrying model request" followed by the app vanishing to the
//  home screen with no crash report:
//
//  1. It was a buffering proxy. `dataTaskWithRequest:completionHandler:` waits
//     for the *entire* response before writing a single byte back, but the
//     request dsh sends is streamed (SSE). The model would sit there producing
//     tokens while this proxy held them all back, dsh saw no first byte, timed
//     out, retried -- and every retry opened another connection holding another
//     complete upstream response in memory. That grows without bound: sockets,
//     threads, NSData buffers. Responses are now relayed as chunks the moment
//     they arrive, so the guest sees the first byte immediately and one request
//     is one in-flight upstream request.
//
//  2. It never set SO_NOSIGPIPE. Writing to a socket whose peer has already
//     closed raises SIGPIPE, and iOS terminates the process on SIGPIPE -- no
//     exception, no ObjC crash report, just a dead app. A retrying client
//     guarantees that write: it closes the timed-out connection while the
//     response is still being written. Both the listener and every accepted
//     socket now carry SO_NOSIGPIPE, and EPIPE is handled as an ordinary
//     "client went away" instead of killing the process.
//
//  A concurrency ceiling is enforced as well: past it a request is refused
//  immediately rather than allowed to queue up into another pile.
//

#import "DSHModelForwarder.h"
#import "DSHHarness.h"
#import "DSHPortAllocator.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSTimeInterval kForwardTimeout = 300;
static const NSTimeInterval kForwardResourceTimeout = 3600;
static const NSUInteger kMaxRequestBytes = 32 * 1024 * 1024;
/// How many forwarded requests may be in flight at once. The terminal needs one,
/// a retry may add a second; more than this means something is looping, and
/// refusing is far better than accumulating sockets until the app is killed.
static const NSUInteger kMaxConcurrentForwards = 8;
/// A forwarded request older than this is treated as lost and its slot reclaimed.
/// Nothing legitimate runs this long, and the cap is useless if the slots of
/// requests abandoned by a backgrounded (or killed) app are never returned.
static const NSTimeInterval kForwardStaleSeconds = 240;

static NSUInteger gActiveForwards = 0;
static NSLock *gForwardLock = nil;

/// The lock is created on first use rather than by the singleton, so slot
/// accounting cannot run against a nil lock if a connection ever arrives first.
static void DSHEnsureForwardLock(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gForwardLock = [NSLock new]; });
}

static BOOL DSHTakeForwardSlot(void) {
    DSHEnsureForwardLock();
    BOOL granted = NO;
    [gForwardLock lock];
    if (gActiveForwards < kMaxConcurrentForwards) {
        gActiveForwards += 1;
        granted = YES;
    }
    [gForwardLock unlock];
    return granted;
}

static void DSHReleaseForwardSlot(void) {
    DSHEnsureForwardLock();
    [gForwardLock lock];
    if (gActiveForwards > 0)
        gActiveForwards -= 1;
    [gForwardLock unlock];
}

#pragma mark - One forwarded request

/// Owns one client socket and the upstream task feeding it.
///
/// The fd is closed exactly once, from whichever side finishes first: the
/// upstream task completing, or a failed write proving the client is gone.
@interface DSHForwardConnection : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) int fd;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL headSent;
/// YES once this connection holds one of the in-flight slots, so it is given
/// back exactly once and never for a request that was refused.
@property (nonatomic) BOOL slotHeld;
@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *task;
@property (nonatomic, copy) NSString *label;
/// When this request started, for the stale-request sweep.
@property (nonatomic, strong) NSDate *startedAt;
@end

@implementation DSHForwardConnection

- (instancetype)initWithSocket:(int)fd label:(NSString *)label {
    if ((self = [super init])) {
        _fd = fd;
        _label = label;
        _startedAt = [NSDate date];
    }
    return self;
}

- (void)dealloc {
    if (_fd >= 0) {
        close(_fd);
        _fd = -1;
    }
}

/// Send bytes, tolerating a client that has gone away.
/// @returns NO when nothing more can be written to this client.
- (BOOL)writeBytes:(const void *)bytes length:(NSUInteger)length {
    const uint8_t *cursor = bytes;
    NSUInteger remaining = length;
    while (remaining > 0) {
        ssize_t written = send(self.fd, cursor, remaining, 0);
        if (written > 0) {
            cursor += written;
            remaining -= (NSUInteger) written;
            continue;
        }
        if (written < 0 && errno == EINTR)
            continue;
        // EPIPE/ECONNRESET: the guest gave up on this request. Ordinary, and
        // never fatal -- SO_NOSIGPIPE is what keeps it that way.
        return NO;
    }
    return YES;
}

- (BOOL)writeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    return [self writeBytes:data.bytes length:data.length];
}

/// Relay one body chunk in HTTP/1.1 chunked framing. The upstream length is not
/// known in advance -- that is the whole point of streaming -- so the response
/// cannot carry Content-Length.
- (BOOL)writeChunk:(NSData *)data {
    if (data.length == 0)
        return YES;
    if (![self writeString:[NSString stringWithFormat:@"%lx\r\n", (unsigned long) data.length]])
        return NO;
    if (![self writeBytes:data.bytes length:data.length])
        return NO;
    return [self writeString:@"\r\n"];
}

- (void)sendHeadWithStatus:(NSInteger)status reason:(NSString *)reason contentType:(NSString *)contentType {
    if (self.headSent)
        return;
    self.headSent = YES;
    [self writeString:[NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long) status, reason]];
    [self writeString:[NSString stringWithFormat:@"Content-Type: %@\r\n", contentType ?: @"application/json"]];
    [self writeString:@"Transfer-Encoding: chunked\r\n"];
    [self writeString:@"Cache-Control: no-store\r\n"];
    [self writeString:@"Connection: close\r\n\r\n"];
}

- (void)refuseWithStatus:(NSInteger)status reason:(NSString *)reason message:(NSString *)message {
    [self sendHeadWithStatus:status reason:reason contentType:@"text/plain; charset=utf-8"];
    [self writeChunk:[message dataUsingEncoding:NSUTF8StringEncoding]];
    [self finish];
}

/// Terminate the exchange: end the chunked body, then close the socket once.
- (void)finish {
    if (self.finished)
        return;
    self.finished = YES;
    if (!self.headSent)
        [self sendHeadWithStatus:502 reason:@"Bad Gateway" contentType:@"text/plain; charset=utf-8"];
    [self writeString:@"0\r\n\r\n"];
    if (self.fd >= 0) {
        close(self.fd);
        self.fd = -1;
    }
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.session = nil;
    self.task = nil;
    if (self.slotHeld) {
        self.slotHeld = NO;
        DSHReleaseForwardSlot();
    }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *) response : nil;
    NSInteger status = http != nil ? http.statusCode : 200;
    NSString *reason = [NSHTTPURLResponse localizedStringForStatusCode:status];
    NSString *contentType = http.allHeaderFields[@"Content-Type"] ?: @"application/json";
    [self sendHeadWithStatus:status reason:reason.length > 0 ? reason : @"OK" contentType:contentType];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (![self writeChunk:data]) {
        // The client is gone; stop pulling from upstream instead of buffering a
        // response nobody will read.
        [dataTask cancel];
        [self finish];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error != nil && !self.headSent) {
        NSString *message = error.localizedDescription ?: @"upstream failed";
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[dsh-ios] forward %@ failed: %@", self.label, message]];
        [self refuseWithStatus:502 reason:@"Bad Gateway" message:message];
        return;
    }
    [self finish];
}

@end

#pragma mark - The listener

@interface DSHModelForwarder ()
@property (nonatomic) int listenFD;
@property (nonatomic) uint16_t port;
@property (nonatomic) BOOL running;
@property (nonatomic, strong) dispatch_queue_t acceptQueue;
@property (nonatomic, strong) dispatch_queue_t workQueue;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong, readwrite) NSString *upstream;
/// Requests accepted and not yet finished, swept for the ones that were lost.
@property (nonatomic, strong) NSMutableArray<DSHForwardConnection *> *live;
@property (nonatomic, strong) NSLock *liveLock;
@end

@implementation DSHModelForwarder

+ (instancetype)shared {
    static DSHModelForwarder *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DSHEnsureForwardLock();
        shared = [[DSHModelForwarder alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _acceptQueue = dispatch_queue_create("dsh.model-forwarder.accept", DISPATCH_QUEUE_SERIAL);
        // Connections run on a concurrent queue: a request that is still being
        // read must never hold up the accept handler, or the listener stops
        // taking new work while one slow client sits there.
        _workQueue = dispatch_queue_create("dsh.model-forwarder.work", DISPATCH_QUEUE_CONCURRENT);
        _live = [NSMutableArray array];
        _liveLock = [NSLock new];
        NSString *override = NSProcessInfo.processInfo.environment[@"DSH_FORWARD_UPSTREAM"];
        _upstream = override.length > 0 ? override : @"https://api.deepseek.com";
    }
    return self;
}

#pragma mark - Lifecycle

- (BOOL)start {
    @synchronized (self) {
        if (self.running)
            return YES;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
            return NO;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        // Writing to a peer that has closed must return EPIPE, never raise
        // SIGPIPE -- on iOS that signal terminates the process outright.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
        // A predictable port keeps http://127.0.0.1:31337 usable as the base URL
        // even if someone types it into the harness settings by hand.
        uint16_t wanted = [DSHPortAllocator freeLoopbackPortStartingAt:31337 span:10];
        struct sockaddr_in addr = {
            .sin_len = sizeof(addr),
            .sin_family = AF_INET,
            .sin_port = htons(wanted),
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK),   // loopback only
        };
        if (bind(fd, (struct sockaddr *) &addr, sizeof(addr)) < 0 || listen(fd, 16) < 0) {
            close(fd);
            return NO;
        }
        socklen_t len = sizeof(addr);
        getsockname(fd, (struct sockaddr *) &addr, &len);
        self.port = ntohs(addr.sin_port);
        self.listenFD = fd;

        __weak typeof(self) weakSelf = self;
        self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self.acceptQueue);
        dispatch_source_set_event_handler(self.acceptSource, ^{ [weakSelf acceptOne]; });
        dispatch_resume(self.acceptSource);
        self.running = YES;
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[dsh-ios] model forwarder listening on 127.0.0.1:%u -> %@", self.port, self.upstream]];
        return YES;
    }
}

- (void)stop {
    @synchronized (self) {
        if (!self.running)
            return;
        self.running = NO;
        if (self.acceptSource) {
            dispatch_source_cancel(self.acceptSource);
            self.acceptSource = nil;
        }
        if (self.listenFD >= 0) {
            close(self.listenFD);
            self.listenFD = -1;
        }
    }
}

/// Re-create the listening socket, keeping the same port.
///
/// iOS hands a suspended app back with its sockets torn down -- iSH's own
/// sockrestart comments call this out as a work of the platform, and it is why
/// the terminal works right after a launch and then degrades to "retrying model
/// request": the app-side listener was closed while the app was in the
/// background, nothing rebinds it, every connect from the guest is refused, and
/// dsh sees a transport failure. Re-arming on foreground is the smallest fix that
/// matches the failure; the port stays 31337 because the guest's base URL is
/// already written.
- (void)restart {
    @synchronized (self) {
        uint16_t previous = self.port;
        [self stop];
        if ([self start]) {
            if (previous != 0 && self.port != previous) {
                [DSHHarness.shared.log append:[NSString stringWithFormat:
                    @"[dsh-ios] model forwarder re-armed on a different port (%u, was %u); the guest is still pointed at %u",
                    self.port, previous, previous]];
            } else {
                [DSHHarness.shared.log append:[NSString stringWithFormat:
                    @"[dsh-ios] model forwarder re-armed on 127.0.0.1:%u", self.port]];
            }
        } else {
            [DSHHarness.shared.log append:@"[dsh-ios] model forwarder could NOT re-arm after the app was suspended"];
        }
    }
}

- (NSString *)baseURLString {
    return self.running ? [NSString stringWithFormat:@"http://127.0.0.1:%u", self.port] : nil;
}

- (NSDictionary<NSString *, NSString *> *)guestEnvironment {
    NSString *base = self.baseURLString;
    if (base == nil)
        return @{};
    // dsh reads the standard proxy-less base URL from the environment, exactly
    // as its own test suite drives it.
    return @{ @"DEEPSEEK_BASE_URL": base };
}

#pragma mark - Serving

- (void)acceptOne {
    int client = accept(self.listenFD, NULL, NULL);
    if (client < 0)
        return;
    int one = 1;
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    // Load-bearing: an EPIPE from this socket must be an error return, not a
    // process-killing signal. A retrying client makes that write certain.
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    struct timeval tv = { .tv_sec = (int) kForwardTimeout };
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    dispatch_async(self.workQueue, ^{ [self serveConnection:client]; });
}

/// Reads the whole request (headers + Content-Length body) before returning.
static NSData *DSHReadRequest(int fd, NSUInteger *headerLength) {
    NSMutableData *buffer = [NSMutableData data];
    NSData *terminator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    char chunk[8192];
    NSRange split = NSMakeRange(NSNotFound, 0);
    while (split.location == NSNotFound) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0)
            return nil;
        [buffer appendBytes:chunk length:(NSUInteger) n];
        if (buffer.length > kMaxRequestBytes)
            return nil;
        split = [buffer rangeOfData:terminator options:0 range:NSMakeRange(0, buffer.length)];
    }
    NSUInteger head = split.location + terminator.length;
    if (headerLength)
        *headerLength = head;

    NSString *headText = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, split.location)]
                                               encoding:NSUTF8StringEncoding];
    if (headText == nil)
        return nil;

    NSUInteger contentLength = 0;
    for (NSString *line in [headText componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        if ([name isEqualToString:@"content-length"]) {
            contentLength = (NSUInteger) [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].integerValue;
        }
    }
    while (buffer.length < head + contentLength) {
        ssize_t n = recv(fd, chunk, sizeof(chunk), 0);
        if (n <= 0)
            return nil;
        [buffer appendBytes:chunk length:(NSUInteger) n];
        if (buffer.length > kMaxRequestBytes)
            return nil;
    }
    return buffer;
}

/// Reclaim slots held by requests that will never finish.
///
/// A request outlives its client whenever iOS suspends or kills the app: the
/// socket dies, no delegate callback ever arrives, and its slot stays taken. With
/// a fixed cap that is fatal -- after a handful of suspensions the forwarder
/// refuses everything and the terminal shows "retrying model request 5/5" forever
/// (the cap exists precisely to stop a retry storm, so it must not become one).
/// Stale entries are collected under the lock and finished after releasing it:
/// finishing takes the slot lock, and the two must never be held together.
- (void)sweepStaleConnections {
    NSDate *now = [NSDate date];
    NSMutableArray<DSHForwardConnection *> *stale = [NSMutableArray array];
    [self.liveLock lock];
    NSMutableArray<DSHForwardConnection *> *keep = [NSMutableArray arrayWithCapacity:self.live.count];
    for (DSHForwardConnection *connection in self.live) {
        if (connection.finished) continue;
        if ([now timeIntervalSinceDate:connection.startedAt] > kForwardStaleSeconds)
            [stale addObject:connection];
        else
            [keep addObject:connection];
    }
    self.live = keep;
    [self.liveLock unlock];
    for (DSHForwardConnection *connection in stale) {
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[dsh-ios] forward %@ held a slot for over %d s; reclaiming it",
            connection.label, (int) kForwardStaleSeconds]];
        [connection finish];
    }
}
- (void)serveConnection:(int)fd {
    [self sweepStaleConnections];
    NSUInteger headLength = 0;
    NSData *raw = DSHReadRequest(fd, &headLength);
    if (raw == nil || headLength == 0) {
        close(fd);
        return;
    }
    NSString *headText = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, headLength - 4)]
                                               encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [headText componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        close(fd);
        return;
    }

    NSArray<NSString *> *requestLine = [lines[0] componentsSeparatedByString:@" "];
    NSString *method = requestLine.count > 0 ? requestLine[0] : @"POST";
    NSString *path = requestLine.count > 1 ? requestLine[1] : @"/";
    NSData *body = raw.length > headLength ? [raw subdataWithRange:NSMakeRange(headLength, raw.length - headLength)] : [NSData data];

    DSHForwardConnection *connection = [[DSHForwardConnection alloc] initWithSocket:fd
                                                                             label:[NSString stringWithFormat:@"%@ %@", method, path]];
    // Refuse rather than queue: past this many in flight, something is looping,
    // and piling on sockets is what killed the app before. The refusal is logged
    // so a future storm is visible in Diagnostics instead of silent.
    if (!DSHTakeForwardSlot()) {
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[dsh-ios] forward %@ refused: %lu already in flight", connection.label,
            (unsigned long) kMaxConcurrentForwards]];
        [connection refuseWithStatus:503 reason:@"Service Unavailable"
                             message:@"too many forwarded requests in flight\n"];
        return;
    }
    connection.slotHeld = YES;
    [self.liveLock lock];
    [self.live addObject:connection];
    [self.liveLock unlock];

    NSURLComponents *components = [NSURLComponents componentsWithString:self.upstream];
    NSURL *upstreamURL = [NSURL URLWithString:path relativeToURL:components.URL];
    if (upstreamURL == nil) {
        [connection refuseWithStatus:502 reason:@"Bad Gateway" message:@"bad upstream path\n"];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:upstreamURL];
    request.HTTPMethod = method;
    request.HTTPBody = body;
    request.timeoutInterval = kForwardTimeout;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        NSString *name = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *lower = name.lowercaseString;
        // Hop-by-hop headers belong to the client connection, not upstream.
        if ([lower isEqualToString:@"host"] || [lower isEqualToString:@"content-length"] ||
            [lower isEqualToString:@"connection"] || [lower isEqualToString:@"accept-encoding"])
            continue;
        [request setValue:value forHTTPHeaderField:name];
    }
    // Relay the upstream body as it arrives, never in one buffered lump.
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = kForwardTimeout;
    config.timeoutIntervalForResource = kForwardResourceTimeout;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.URLCache = nil;
    config.HTTPShouldUsePipelining = NO;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:connection delegateQueue:nil];
    connection.session = session;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    connection.task = task;
    [task resume];
}

@end
