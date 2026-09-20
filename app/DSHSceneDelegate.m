//
//  DSHSceneDelegate.m
//  DSH
//

#import "DSHSceneDelegate.h"
#if DSH_CLI_ONLY
#import "DSHCLIViewController.h"
#else
#import "DSHRootViewController.h"
#endif
#import "AppDelegate.h"
#import "AboutViewController.h"

@implementation DSHSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *) scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        // Same escape hatch as iSH: the kernel is not booted, only settings.
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        ((AboutViewController *) vc.topViewController).recoveryMode = YES;
        self.window.rootViewController = vc;
    } else {
#if DSH_CLI_ONLY
        // CLI-only build: same guest, terminal front end, no web server.
        self.window.rootViewController = [[DSHCLIViewController alloc] init];
#else
        self.window.rootViewController = [[DSHRootViewController alloc] init];
#endif
    }
    [self.window makeKeyAndVisible];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
#if !DSH_CLI_ONLY
    UIViewController *root = self.window.rootViewController;
    if ([root isKindOfClass:DSHRootViewController.class])
        [(DSHRootViewController *) root sceneDidBecomeActive];
#endif
}

@end
