//
//  DSHBootCoordinator.m
//  DSH
//

#import "DSHBootCoordinator.h"
#import "DSHHarness.h"
#import "DSHRootUpgrader.h"
#import "DSHHostBridge.h"
#import "DSHModelForwarder.h"
#import "DSHDeviceCapability.h"
#import "DSHEventKitCapability.h"
#import "DSHHealthCapability.h"
#import "DSHLocationCapability.h"
#import "DSHContactsCapability.h"
#import "DSHNotificationCapability.h"
#import "DSHFilesCapability.h"
#import "DSHPhotosCapability.h"
#import "DSHShareCapability.h"
#import "DSHShortcutsCapability.h"
#import "DSHActivityCapability.h"
#import "DSHStartupMetrics.h"
#import "AppDelegate.h"
#import "ISHShellExecutor.h"
#import <UIKit/UIKit.h>

NSNotificationName const DSHBootStateDidChangeNotification = @"DSHBootStateDidChangeNotification";

// -boot lives in iSH's AppDelegate implementation; it is safe to run on any
// single thread because `current` is thread-local.
@interface AppDelegate (DSHBoot)
- (int)boot;
@end

@interface DSHBootCoordinator ()
@property (nonatomic, readwrite) DSHBootPhase phase;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, readwrite, copy) NSString *statusMessage;
@property (nonatomic, readwrite) int bootError;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) BOOL started;
@end

@implementation DSHBootCoordinator

+ (instancetype)shared {
    static DSHBootCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [DSHBootCoordinator new]; });
    return shared;
}

- (instancetype)init {
    if (self = [super init]) {
        // Serial and high priority: the whole guest lives on this thread until
        // init is started, and the user is staring at a spinner meanwhile.
        _queue = dispatch_queue_create("app.dsh.boot", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
        _statusMessage = @"正在准备 Linux 环境…";
        _progress = -1;
    }
    return self;
}

- (void)setPhase:(DSHBootPhase)phase message:(NSString *)message progress:(double)progress {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_phase = phase;
        self->_statusMessage = [message copy];
        self->_progress = progress;
        [NSNotificationCenter.defaultCenter postNotificationName:DSHBootStateDidChangeNotification object:self];
    });
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"start on main");
    if (self.started)
        return;
    self.started = YES;
    [DSHStartupMetrics.shared beginLaunch];
    [DSHHarness.shared.log append:@"[perf] app boot coordinator started"];
    [self setPhase:DSHBootPhaseImportingImage message:@"正在准备 Linux 环境…" progress:-1];
    // UIApplication is main-thread-only; grab the delegate here, not on the queue.
    AppDelegate *app = (AppDelegate *) UIApplication.sharedApplication.delegate;

    dispatch_async(self.queue, ^{
        NSDate *t0 = NSDate.date;
        // 1. Import the bundled image when this build ships a new one. On a
        //    fresh install this is where the 95 MB root filesystem lands.
        DSHRootUpgrader *upgrader = DSHRootUpgrader.shared;
        [upgrader prepareRootsBeforeBootWithProgress:^(double fraction, NSString *message) {
            [self setPhase:DSHBootPhaseImportingImage
                   message:message.length ? message : @"正在安装 Linux 镜像…"
                  progress:fraction];
        }];
        NSTimeInterval imported = -t0.timeIntervalSinceNow;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[perf] image preparation %.3fs", imported]];
        [DSHStartupMetrics.shared mark:@"image_ready"];

        // 2. Boot the emulator kernel (mount the fakefs, start init).
        [self setPhase:DSHBootPhaseBootingKernel message:@"正在启动 Linux 客户机…" progress:-1];
        int err = [app boot];
        NSTimeInterval kernelBoot = -t0.timeIntervalSinceNow - imported;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[perf] guest kernel boot %.3fs", kernelBoot]];
        [DSHStartupMetrics.shared mark:@"kernel_ready"];
        self.bootError = err;
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] guest boot %@ (image %.1fs, total %.1fs)",
                                       err == 0 ? @"ok" : [NSString stringWithFormat:@"failed: %d", err],
                                       imported, -t0.timeIntervalSinceNow]];
        if (err < 0) {
            [self setPhase:DSHBootPhaseFailed
                   message:[NSString stringWithFormat:@"Linux 客户机启动失败（错误 %d）。", err]
                  progress:-1];
            return;
        }

        // 3. Migrate user data from a previous root, then let the harness run.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (upgrader.pendingMigrationRoot != nil) {
                [self setPhase:DSHBootPhaseMigratingData message:@"正在把会话迁移到新镜像…" progress:-1];
                [upgrader migrateIfNeededWithCompletion:^(BOOL migrated, NSError *error) {
                    if (error)
                        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] migration problem: %@", error.localizedDescription]];
                    [self finishReady];
                }];
            } else {
                [self finishReady];
            }
        });
    });
}

- (void)finishReady {
    // The host bridge must be listening before dsh-serve starts: its URL and
    // token reach the guest through the server's environment.
    DSHHostBridge *bridge = DSHHostBridge.shared;
    [DSHDeviceCapability installOn:bridge];
    [DSHEventKitCapability installOn:bridge];
    [DSHHealthCapability installOn:bridge];
    [DSHLocationCapability installOn:bridge];
    [DSHContactsCapability installOn:bridge];
    [DSHNotificationCapability installOn:bridge];
    [DSHFilesCapability installOn:bridge];
    [DSHPhotosCapability installOn:bridge];
    [DSHShareCapability installOn:bridge];
    [DSHShortcutsCapability installOn:bridge];
    [DSHActivityCapability installOn:bridge];
    if ([bridge start]) {
        NSMutableDictionary *env = [DSHHarness.shared.extraEnvironment mutableCopy];
        [env addEntriesFromDictionary:bridge.guestEnvironment];
        // Model traffic leaves through the host. Inside the app the guest's
        // sockets are passed through to the host, but iOS refuses the host's
        // outbound connects on some systems: the guest then sees
        // EHOSTUNREACH for every non-loopback address while loopback keeps
        // working, so no model request can go out. The app itself has network,
        // so the guest talks plain HTTP to this loopback forwarder instead.
        if ([DSHModelForwarder.shared start])
            [env addEntriesFromDictionary:DSHModelForwarder.shared.guestEnvironment];
        else
            [DSHHarness.shared.log append:@"[dsh-ios] model forwarder could not start; the guest will call the model API directly"];
        DSHHarness.shared.extraEnvironment = env;
        [self writeGuestShellEnvironment:env];
    } else {
        [DSHHarness.shared.log append:@"[dsh-ios] host bridge could not start; iOS capabilities are unavailable"];
    }
    [DSHStartupMetrics.shared mark:@"bridge_ready"];
#if DSH_CLI_ONLY
    // The TUI build has nothing to supervise: `dsh-tui` runs dsh's interactive
    // headless form in the terminal, with no listening port, no WKWebView and
    // none of the client-plugin bundling that dominates startup. Starting
    // dsh-serve here would only spend the guest's CPU on a server no part of
    // this app ever connects to.
    [DSHHarness.shared.log append:@"[dsh-ios] CLI-only build: no dsh-serve to start"];
    [self setPhase:DSHBootPhaseReady message:@"正在启动 harness 终端…" progress:-1];
#else
    [self setPhase:DSHBootPhaseReady message:@"正在启动 DeepSeek Harness…" progress:-1];
    [DSHHarness.shared start];
#endif
}

/// Terminal sessions inherit nothing but TERM (see
/// -[TerminalViewController startSession]), so environment the app wants the
/// guest's shells to have has to be written into the guest instead of exported.
/// `dsh-tui` and /etc/profile.d/dsh-forwarder.sh read this file.
///
/// Synchronous on purpose: the TUI build hands the screen to `dsh-tui` the
/// moment the boot phase turns ready, and the bridge URL has to be on disk
/// before that terminal starts.
- (void)writeGuestShellEnvironment:(NSDictionary<NSString *, NSString *> *)environment {
    if (environment.count == 0)
        return;
    NSMutableString *body = [NSMutableString string];
    for (NSString *key in [environment.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [body appendFormat:@"%@='%@'\n", key, environment[key]];
    // A quoted heredoc delimiter passes the body through verbatim; every value
    // here is a URL or hex token this app generated, so none can contain a line
    // equal to the delimiter.
    NSString *script = [NSString stringWithFormat:
        @"umask 077\nmkdir -p /root/.dsh\ncat > /root/.dsh/.host-bridge.env <<'DSH_ENV_EOF'\n%@DSH_ENV_EOF\n",
        body];
    ISHShellExecutionResult *result = [ISHShellExecutor executeCommandSync:script timeout:5 lineCallback:nil];
    if (result.exitCode != 0)
        [DSHHarness.shared.log append:[NSString stringWithFormat:
            @"[dsh-ios] could not write the guest shell environment (exit %d, error %d)",
            result.exitCode, (int) result.error]];
}

@end
