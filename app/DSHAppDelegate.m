//
//  DSHAppDelegate.m
//  DSH
//

#import "DSHAppDelegate.h"
#import "DSHBootCoordinator.h"
#import "DSHModelForwarder.h"
#import "DSHHarness.h"
#import <mach/mach.h>
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
#import <os/proc.h>
#endif
#if !DSH_CLI_ONLY
#import "DSHRootViewController.h"
#endif

// Survival probes.
//
// The two ways this app ends on its own look identical from outside: a crash and
// a jetsam kill both leave the Diagnostics file stopping mid-line, with nothing
// after it. That ambiguity has cost this project real time -- the guest's harness
// is killed whenever the app goes away, and "something killed node" had to be
// separated from "something killed the app" by hand. So both are made explicit:
//
//   1. Crash: an uncaught exception and the fatal signals write their own line
//      through a descriptor opened before the failure (the only async-signal-safe
//      way to report from a handler), then re-raise so the failure still behaves
//      like one.
//   2. Memory: the footprint jetsam accounts, plus the headroom the platform says
//      is left, logged every 20 seconds and on every memory warning. A kill by
//      memory pressure then has a trend attached to it instead of a hypothesis.
static int dshCrashFd = -1;

static void DSHCrashNote(const char *what) {
    if (dshCrashFd < 0)
        return;
    char buffer[192];
    int n = snprintf(buffer, sizeof(buffer), "%s\n", what);
    if (n > 0) {
        ssize_t ignored = write(dshCrashFd, buffer, (size_t) n);
        (void) ignored;
    }
}

static void DSHFatalSignalHandler(int sig) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "fatal signal %d, backtrace:", sig);
    DSHCrashNote(buffer);
    // A signal number alone says "it trapped", not where. backtrace_symbols_fd
    // writes straight to the descriptor without allocating, which is what makes
    // a stack usable from inside a handler at all.
    void *frames[64];
    int depth = backtrace(frames, 64);
    if (dshCrashFd >= 0 && depth > 0)
        backtrace_symbols_fd(frames, depth, dshCrashFd);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void DSHUncaughtExceptionHandler(NSException *exception) {
    NSString *line = [NSString stringWithFormat:@"uncaught exception %@: %@\n%@",
                      exception.name, exception.reason, exception.callStackSymbols];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (dshCrashFd >= 0 && data.length > 0) {
        ssize_t ignored = write(dshCrashFd, data.bytes, data.length);
        (void) ignored;
    }
}

static NSString *DSHMemoryLine(void) {
    unsigned long long footprint = 0;
    struct task_vm_info info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS)
        footprint = (unsigned long long) info.phys_footprint;
    unsigned long long headroom = 0;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (@available(iOS 13.0, *))
        headroom = (unsigned long long) os_proc_available_memory();
#endif
    return [NSString stringWithFormat:@"memory footprint=%.0fMB headroom=%.0fMB",
                                      footprint / 1048576.0, headroom / 1048576.0];
}

static NSString *const kCapabilityPreferenceRepair = @"DSHCapabilityPreferenceRepair.2";

static void DSHRepairPreferencesPollutedByLegacyTests(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:kCapabilityPreferenceRepair])
        return;

    // Builds through 1.0.13 ran unit tests inside the application process and
    // wrote their temporary capability switches into the production defaults.
    // An App Store/TestFlight update preserves those defaults. Forget only this
    // namespace once so every capability returns to its declared product
    // default; HealthKit and the other system privacy choices are untouched.
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"DSHCapabilityEnabled."])
            [defaults removeObjectForKey:key];
    }
    [defaults setBool:YES forKey:kCapabilityPreferenceRepair];
}

@interface DSHAppDelegate ()
- (void)dshInstallSurvivalProbes;
@end

// iSH's AppDelegate boots the kernel inside -willFinishLaunching. That takes
// far longer than iOS's launch watchdog allows on a phone (importing the guest
// image alone can take a minute), so DSH overrides both launch methods, keeps
// only their cheap parts, and lets DSHBootCoordinator do the work in the
// background while the UI is already on screen.
@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {
    DSHRepairPreferencesPollutedByLegacyTests();
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"hail mary"]) {
        [defaults removeObjectForKey:@"Boot Command"];
        [defaults removeObjectForKey:@"Init Command"];
        [defaults setBool:NO forKey:@"hail mary"];
    }
    return YES;   // deliberately no [super ...]: that would boot synchronously
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"])
        return YES;
    [self dshInstallSurvivalProbes];
    // Kicks off image import → kernel boot → data migration → harness start.
    [DSHBootCoordinator.shared start];
    return YES;
}

/// Open the crash note, arm the handlers, and start the memory sampler.
///
/// The crash note is a file rather than the log buffer because a signal handler
/// cannot touch Foundation (no locks, no allocation), and because this file is
/// the one thing that can be written while the process is already failing.
- (void)dshInstallSurvivalProbes {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *support = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"Diagnostics" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir URLByAppendingPathComponent:@"app-survival.log"].path;
    if (![fm fileExistsAtPath:path])
        [fm createFileAtPath:path contents:nil attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication}];
    dshCrashFd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    NSSetUncaughtExceptionHandler(&DSHUncaughtExceptionHandler);
    for (int sig = 0; sig < NSIG; sig++) {
        switch (sig) {
            case SIGABRT: case SIGSEGV: case SIGBUS: case SIGILL: case SIGFPE: case SIGTRAP:
                signal(sig, DSHFatalSignalHandler);
                break;
            default:
                break;
        }
    }
    [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] probes armed; %@", DSHMemoryLine()]];
    NSTimer *sampler = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *timer) {
        [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] %@", DSHMemoryLine()]];
    }];
    sampler.tolerance = 5;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    [DSHHarness.shared.log append:[NSString stringWithFormat:@"[dsh-ios] MEMORY WARNING %@", DSHMemoryLine()]];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // Suspension may have broken the guest's sockets. Confirm the server still
    // answers; DSHHarness restarts it otherwise and the UI reloads.
    [DSHHarness.shared verifyAliveWithCompletion:nil];
    // A boot that was interrupted by suspension has not had its time yet: the
    // guest is frozen while we are away, so the startup deadline has to start
    // counting again instead of firing the moment we come back.
    [DSHHarness.shared noteForeground];
    // Suspension closes this app's sockets; without re-arming, the guest's model
    // requests are refused from then on and the terminal retries forever.
    [DSHModelForwarder.shared ensureListening];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // The same check from the other lifecycle door: a resume can arrive as
    // `didBecomeActive` (unlock, Control Center dismissal) without a preceding
    // `willEnterForeground`, and this is the hook that always fires. It is
    // idempotent -- it re-arms only when the listener is genuinely gone -- so
    // calling it on both paths costs nothing.
    [DSHModelForwarder.shared ensureListening];
}

@end
