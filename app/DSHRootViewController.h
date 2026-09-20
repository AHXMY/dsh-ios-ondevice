//
//  DSHRootViewController.h
//  DSH
//
//  The app's single screen: a WKWebView showing the DeepSeek Harness web UI
//  served by the guest, a startup/status overlay while the server is not
//  answering, and a small control bar (terminal, reload, restart, log).
//
//  Browser build only. The CLI build (-DDSH_CLI_ONLY=1) is a terminal running
//  the guest's 	ui profile, with none of this in the binary.
//

#if !DSH_CLI_ONLY

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DSHRootViewController : UIViewController

- (void)sceneDidBecomeActive;

- (void)reloadWebView;
- (void)presentTerminal;
- (void)presentLog;

@end

NS_ASSUME_NONNULL_END

#endif
