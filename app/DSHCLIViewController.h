//
//  DSHCLIViewController.h
//  DSH
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Root view controller of the CLI-only build (`GCC_PREPROCESSOR_DEFINITIONS`
/// carrying `DSH_CLI_ONLY=1`).
///
/// It boots the same Linux guest as the browser build, then hands the whole
/// screen to a terminal running the guest's `dsh-tui`. Nothing else is started:
/// no `dsh-serve`, no listening port, no WKWebView, and therefore none of the
/// client-plugin bundling that dominates startup under emulation, and no
/// liveness checks that can mistake a busy guest for a dead server.
@interface DSHCLIViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
