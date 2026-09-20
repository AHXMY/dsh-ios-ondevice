//
//  DSHModelForwarder.m
//  DSH
//

#import "DSHModelForwarder.h"
#import "DSHHarness.h"
#import "DSHPortAllocator.h"

#import <arpa/inet.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSTimeInterval kForwardTimeout = 180;
static const NSUInteger kMaxRequestBytes = 32 * 1024 * 1024;

@interface DSHModelForwarder ()
@property (nonatomic) int listenFD;
@property (nonatomic) uint16_t port;
@property (nonatomic) BOOL running;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong, readwrite) NSString *upstream;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation DSHModelForwarder

+ (instancetype)shared {
    static DSHModelForwarder *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[DSHModelForwarder alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _listenFD = -1;
        _queue = dispatch_queue_create("dsh.model-forwarder", DISPATCH_QUEUE_SERIAL);
        NSString *override = NSProcessInfo.processInfo.environment[@"DSH_FORWARD_UPSTREAM"];
        _upstream = override.length > 0 ? override : @"https://api.deepseek.com";
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = kForwardTimeout;
        config.timeoutIntervalForResource = kForwardTimeout;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:config];
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
        self.acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self.queue);
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
    struct timeval tv = { .tv_sec = (int) kForwardTimeout };
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    dispatch_async(self.queue, ^{ [self serveConnection:client]; });
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

- (void)serveConnection:(int)fd {
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

    NSURLComponents *components = [NSURLComponents componentsWithString:self.upstream];
    NSURL *upstreamURL = [NSURL URLWithString:path relativeToURL:components.URL];
    if (upstreamURL == nil) {
        [self reply:fd status:502 reason:@"Bad Gateway" contentType:@"text/plain"
               body:[@"bad upstream path" dataUsingEncoding:NSUTF8StringEncoding]];
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

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        typeof(self) self = weakSelf;
        if (self == nil)
            return;
        if (error != nil || data == nil) {
            NSString *message = error.localizedDescription ?: @"upstream failed";
            [self reply:fd status:502 reason:@"Bad Gateway" contentType:@"text/plain"
                   body:[message dataUsingEncoding:NSUTF8StringEncoding]];
            [DSHHarness.shared.log append:[NSString stringWithFormat:
                @"[dsh-ios] forward %@ %@ failed: %@", method, path, message]];
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *) response : nil;
        NSInteger status = http != nil ? http.statusCode : 200;
        NSString *contentType = http.allHeaderFields[@"Content-Type"] ?: @"application/json";
        [self reply:fd status:status reason:@"OK" contentType:contentType body:data];
    }];
    [task resume];
}

- (void)reply:(int)fd status:(NSInteger)status reason:(NSString *)reason contentType:(NSString *)contentType body:(NSData *)body {
    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"HTTP/1.1 %ld %@\r\n", (long) status, reason];
    [head appendFormat:@"Content-Type: %@\r\n", contentType];
    [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long) body.length];
    [head appendString:@"Connection: close\r\n\r\n"];
    NSMutableData *payload = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [payload appendData:body];
    const uint8_t *bytes = payload.bytes;
    size_t remaining = payload.length;
    while (remaining > 0) {
        ssize_t written = send(fd, bytes, remaining, 0);
        if (written <= 0)
            break;
        bytes += written;
        remaining -= (size_t) written;
    }
    close(fd);
}

@end
