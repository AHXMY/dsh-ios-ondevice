//
//  DSHAppDelegate.m
//  DSH
//

#import "DSHAppDelegate.h"
#import "DSHBootCoordinator.h"
#import "DSHModelForwarder.h"
#import "DSHHarness.h"
#if !DSH_CLI_ONLY
#import "DSHRootViewController.h"
#endif

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
    // Kicks off image import → kernel boot → data migration → harness start.
    [DSHBootCoordinator.shared start];
    return YES;
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
    [DSHModelForwarder.shared restart];
}

@end
