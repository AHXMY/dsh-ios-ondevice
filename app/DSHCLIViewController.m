//
//  DSHCLIViewController.m
//  DSH
//

#import "DSHCLIViewController.h"
#import "DSHBootCoordinator.h"
#import "DSHHarness.h"
#import "TerminalViewController.h"
#import "UserPreferences.h"

@interface DSHCLIViewController ()
@property (nonatomic) UILabel *statusLabel;
@property (nonatomic) UIActivityIndicatorView *spinner;
@property (nonatomic, nullable) TerminalViewController *terminalVC;
@property (nonatomic) BOOL handedOff;
@end

@implementation DSHCLIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorNamed:@"DSHBackground"] ?: UIColor.systemBackgroundColor;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    label.text = @"Preparing the Linux environment…";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ spinner, label ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];

    self.spinner = spinner;
    self.statusLabel = label;

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(bootStateChanged:)
                                               name:DSHBootStateDidChangeNotification
                                             object:nil];
    [self updateWithPhase:DSHBootCoordinator.shared.phase message:DSHBootCoordinator.shared.statusMessage];
    // The app delegate starts this too; the call is idempotent and keeps the
    // CLI build working if that ordering ever changes.
    [DSHBootCoordinator.shared start];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)bootStateChanged:(NSNotification *)note {
    DSHBootCoordinator *boot = note.object;
    if (![boot isKindOfClass:DSHBootCoordinator.class])
        return;
    [self updateWithPhase:boot.phase message:boot.statusMessage];
}

- (void)updateWithPhase:(DSHBootPhase)phase message:(NSString *)message {
    if (self.handedOff)
        return;
    switch (phase) {
        case DSHBootPhaseFailed:
            [self.spinner stopAnimating];
            self.statusLabel.textColor = UIColor.systemRedColor;
            self.statusLabel.text = message.length ? message : @"The Linux guest failed to boot.";
            return;
        case DSHBootPhaseReady:
            [self handOffToTerminal];
            return;
        default:
            break;
    }
    if (message.length)
        self.statusLabel.text = message;
}

/// The guest is up: give the screen to the CLI and get out of the way.
///
/// The session's command is iSH's "Init Command" preference, read once when a
/// session starts, and it is set *permanently* here rather than swapped for the
/// duration of this one session: -[TerminalViewController processExited:] starts
/// a fresh session as soon as one ends, so a restored preference would drop the
/// user into a plain login shell the moment they type `exit`. Leaving it at
/// `dsh-tui` is what makes this build terminal-only -- every session, now and after
/// a relaunch, is the harness. `!` inside the TUI is the way out to a
/// shell.
- (void)handOffToTerminal {
    if (self.handedOff)
        return;
    self.handedOff = YES;

    // iSH's terminal offers to "install the built-in APK" on first use; the
    // guest ships with apk already, so skip that startup message.
    [NSUserDefaults.standardUserDefaults setInteger:1 forKey:@"Skip Startup Message"];

    UserPreferences.shared.launchCommand = @[ @"/usr/local/bin/dsh-tui" ];

    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Terminal" bundle:nil];
    TerminalViewController *vc = [storyboard instantiateInitialViewController];
    // Nothing here manages the scene; the terminal owns the whole window, so a
    // session ending must not be able to tear it down.
    vc.sceneSession = nil;
    vc.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self addChildViewController:vc];
    [self.view addSubview:vc.view];
    [NSLayoutConstraint activateConstraints:@[
        [vc.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [vc.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [vc.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [vc.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    [vc didMoveToParentViewController:self];

    [vc startNewSession];

    self.terminalVC = vc;
    [self.spinner stopAnimating];
    [self.spinner removeFromSuperview];
    [self.statusLabel removeFromSuperview];
    [DSHHarness.shared.log append:@"[dsh-ios] CLI front end started"];
}

@end
