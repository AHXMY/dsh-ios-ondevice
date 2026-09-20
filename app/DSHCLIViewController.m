//
//  DSHCLIViewController.m
//  DSH
//
//  The CLI build's launch screen: an animated one, because this is what the user
//  stares at for the first seconds of every cold start while the guest image is
//  prepared and ~250 plugin packages load. It shows four concrete steps, ticks
//  them off from DSHBootCoordinator's phases, and only then hands the screen to
//  the terminal. A bare spinner read as "the app is doing nothing".
//

#import "DSHCLIViewController.h"
#import "DSHBootCoordinator.h"
#import "DSHHarness.h"
#import "TerminalViewController.h"
#import "UserPreferences.h"

static const NSUInteger kStepCount = 4;

@interface DSHCLIViewController ()
@property (nonatomic) CAGradientLayer *background;
@property (nonatomic) UILabel *logoLabel;
@property (nonatomic) UILabel *cursorLabel;
@property (nonatomic) UILabel *statusLabel;
@property (nonatomic) NSArray<UILabel *> *stepLabels;
@property (nonatomic) UIProgressView *progressBar;
@property (nonatomic) UILabel *footerLabel;
@property (nonatomic) UIStackView *launchStack;
@property (nonatomic, copy) NSString *logoTarget;
@property (nonatomic) NSUInteger typedCharacters;
@property (nonatomic, nullable) NSTimer *typewriter;
@property (nonatomic, nullable) TerminalViewController *terminalVC;
@property (nonatomic) BOOL handedOff;
@end

@implementation DSHCLIViewController

#pragma mark - Launch screen

- (void)viewDidLoad {
    [super viewDidLoad];
    [self buildBackdrop];
    [self buildContent];
    [self startAnimations];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(bootStateChanged:)
                                               name:DSHBootStateDidChangeNotification
                                             object:nil];
    [self updateWithPhase:DSHBootCoordinator.shared.phase message:DSHBootCoordinator.shared.statusMessage];
    // The app delegate starts this too; the call is idempotent and keeps the
    // CLI build working if that ordering ever changes.
    [DSHBootCoordinator.shared start];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.background.frame = self.view.bounds;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.typewriter invalidate];
}

/// A drifting three-stop gradient: motion in the background, no assets, and it
/// costs nothing while the emulator boots.
- (void)buildBackdrop {
    self.view.backgroundColor = UIColor.blackColor;
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = @[
        (id) [UIColor colorWithRed:0.03 green:0.05 blue:0.12 alpha:1.0].CGColor,
        (id) [UIColor colorWithRed:0.07 green:0.12 blue:0.30 alpha:1.0].CGColor,
        (id) [UIColor colorWithRed:0.16 green:0.08 blue:0.34 alpha:1.0].CGColor,
    ];
    gradient.startPoint = CGPointMake(0.0, 0.0);
    gradient.endPoint = CGPointMake(1.0, 1.0);
    [self.view.layer addSublayer:gradient];
    self.background = gradient;

    CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"startPoint"];
    drift.fromValue = [NSValue valueWithCGPoint:CGPointMake(0.0, 0.0)];
    drift.toValue = [NSValue valueWithCGPoint:CGPointMake(1.0, 1.0)];
    drift.duration = 6.0;
    drift.autoreverses = YES;
    drift.repeatCount = HUGE_VALF;
    drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [gradient addAnimation:drift forKey:@"drift"];

    CABasicAnimation *driftEnd = [CABasicAnimation animationWithKeyPath:@"endPoint"];
    driftEnd.fromValue = [NSValue valueWithCGPoint:CGPointMake(1.0, 1.0)];
    driftEnd.toValue = [NSValue valueWithCGPoint:CGPointMake(0.0, 0.0)];
    driftEnd.duration = 6.0;
    driftEnd.autoreverses = YES;
    driftEnd.repeatCount = HUGE_VALF;
    driftEnd.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [gradient addAnimation:driftEnd forKey:@"driftEnd"];
}

- (void)buildContent {
    UIFont *mono = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold];

    // Pure ASCII so the system monospaced font always has the glyphs.
    self.logoTarget = @"  ____  ____  _   _\n"
                       " |  _ \\/ ___|| | | |\n"
                       " | | | \\___ \\| |_| |\n"
                       " | |_| |___) |  _  |\n"
                       " |____/|____/|_| |_|";

    UILabel *logo = [UILabel new];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.font = mono;
    logo.textColor = [UIColor colorWithRed:0.42 green:0.78 blue:1.0 alpha:1.0];
    logo.numberOfLines = 0;
    logo.textAlignment = NSTextAlignmentLeft;
    logo.text = @"";
    logo.layer.shadowColor = logo.textColor.CGColor;
    logo.layer.shadowOpacity = 0.55;
    logo.layer.shadowRadius = 8.0;
    logo.layer.shadowOffset = CGSizeZero;
    self.logoLabel = logo;

    UILabel *cursor = [UILabel new];
    cursor.translatesAutoresizingMaskIntoConstraints = NO;
    cursor.font = mono;
    cursor.textColor = logo.textColor;
    cursor.text = @"▋";
    cursor.alpha = 0.0;
    self.cursorLabel = cursor;

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = @"DeepSeek Harness · 终端界面";
    subtitle.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    subtitle.adjustsFontForContentSizeCategory = YES;
    subtitle.textColor = UIColor.secondaryLabelColor;

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
    self.statusLabel.adjustsFontForContentSizeCategory = YES;
    self.statusLabel.textColor = UIColor.labelColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"正在准备 Linux 环境…";

    self.progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressBar.progressTintColor = logo.textColor;
    self.progressBar.trackTintColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    self.progressBar.progress = 0.0;

    UIFont *stepFont = [UIFont monospacedSystemFontOfSize:12.5 weight:UIFontWeightRegular];
    NSMutableArray<UILabel *> *steps = [NSMutableArray arrayWithCapacity:kStepCount];
    for (NSString *title in @[ @"准备 Linux 环境", @"启动 Linux 客户机", @"迁移会话数据", @"启动 harness 终端" ]) {
        UILabel *step = [UILabel new];
        step.font = stepFont;
        step.textColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        step.text = [NSString stringWithFormat:@"○  %@", title];
        [steps addObject:step];
    }
    self.stepLabels = steps;

    UIStackView *stepStack = [[UIStackView alloc] initWithArrangedSubviews:steps];
    stepStack.axis = UILayoutConstraintAxisVertical;
    stepStack.spacing = 6;
    stepStack.alignment = UIStackViewAlignmentLeading;

    self.footerLabel = [UILabel new];
    self.footerLabel.text = @"原版 DeepSeek Harness · 模型 deepseek-flash · 推理 max";
    self.footerLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption2];
    self.footerLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.32];
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    self.footerLabel.numberOfLines = 0;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        logo, subtitle, self.statusLabel, self.progressBar, stepStack, self.footerLabel,
    ]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14;
    [stack setCustomSpacing:6 afterView:logo];
    [stack setCustomSpacing:26 afterView:self.statusLabel];
    [stack setCustomSpacing:26 afterView:stepStack];
    self.launchStack = stack;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:28],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.progressBar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
    ]];
}

- (void)startAnimations {
    // Blinking block cursor under the logo.
    self.cursorLabel.alpha = 0.0;
    [UIView animateWithDuration:0.55 delay:0.2 options:UIViewAnimationOptionRepeat | UIViewAnimationOptionAutoreverse | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.cursorLabel.alpha = 1.0; }
                     completion:nil];

    // Typewriter reveal of the wordmark.
    self.typedCharacters = 0;
    self.typewriter = [NSTimer scheduledTimerWithTimeInterval:0.014 repeats:YES block:^(NSTimer *timer) {
        if (self.typedCharacters >= self.logoTarget.length) {
            [timer invalidate];
            self.typewriter = nil;
            return;
        }
        self.typedCharacters += 1;
        self.logoLabel.text = [self.logoTarget substringToIndex:self.typedCharacters];
    }];

    // Indeterminate sweep until a phase reports a real fraction.
    self.progressBar.progress = 0.05;
    CABasicAnimation *sweep = [CABasicAnimation animationWithKeyPath:@"opacity"];
    sweep.fromValue = @1.0;
    sweep.toValue = @0.25;
    sweep.duration = 0.9;
    sweep.autoreverses = YES;
    sweep.repeatCount = HUGE_VALF;
    [self.progressBar.layer addAnimation:sweep forKey:@"pulse"];
}

#pragma mark - Boot progress

- (void)bootStateChanged:(NSNotification *)note {
    DSHBootCoordinator *boot = note.object;
    if (![boot isKindOfClass:DSHBootCoordinator.class])
        return;
    [self updateWithPhase:boot.phase message:boot.statusMessage];
}

/// Index of the step a phase belongs to (kStepCount == done).
static NSUInteger stepForPhase(DSHBootPhase phase) {
    switch (phase) {
        case DSHBootPhaseIdle:           return 0;
        case DSHBootPhaseImportingImage: return 0;
        case DSHBootPhaseBootingKernel:  return 1;
        case DSHBootPhaseMigratingData:  return 2;
        case DSHBootPhaseReady:          return kStepCount;
        case DSHBootPhaseFailed:         return NSNotFound;
    }
    return 0;
}

- (void)updateWithPhase:(DSHBootPhase)phase message:(NSString *)message {
    if (self.handedOff)
        return;

    if (phase == DSHBootPhaseFailed) {
        self.statusLabel.textColor = UIColor.systemRedColor;
        self.statusLabel.text = message.length ? message : @"Linux 客户机启动失败。";
        [self.progressBar.layer removeAllAnimations];
        self.progressBar.progressTintColor = UIColor.systemRedColor;
        return;
    }

    if (message.length)
        self.statusLabel.text = message;
    if (phase == DSHBootPhaseReady) {
        [self handOffToTerminal];
        return;
    }

    NSUInteger current = stepForPhase(phase);
    [self.stepLabels enumerateObjectsUsingBlock:^(UILabel *label, NSUInteger index, BOOL *stop) {
        if (index < current) {
            label.textColor = [UIColor colorWithRed:0.42 green:0.90 blue:0.60 alpha:1.0];
            label.text = [@"●  " stringByAppendingString:[label.text substringFromIndex:3]];
        } else if (index == current) {
            label.textColor = UIColor.whiteColor;
            label.text = [@"▶  " stringByAppendingString:[label.text substringFromIndex:3]];
        } else {
            label.textColor = [UIColor colorWithWhite:1.0 alpha:0.30];
            label.text = [@"○  " stringByAppendingString:[label.text substringFromIndex:3]];
        }
    }];

    double progress = DSHBootCoordinator.shared.progress;
    if (progress >= 0.0) {
        [self.progressBar.layer removeAnimationForKey:@"pulse"];
        self.progressBar.progress = (float) MAX(0.02, MIN(0.99, progress));
    }
}

#pragma mark - Handoff

/// The guest is up: give the screen to the CLI and get out of the way.
///
/// The session's command is iSH's "Init Command" preference, read once when a
/// session starts, and it is set *permanently* here rather than swapped for the
/// duration of this one session: -[TerminalViewController processExited:] starts
/// a fresh session as soon as one ends, so a restored preference would drop the
/// user into a plain login shell the moment they type `exit`. Leaving it at
/// `dsh-tui` is what makes this build terminal-only -- every session, now and after
/// a relaunch, is the harness.
///
/// That also means there is no plain shell prompt in this build. An earlier
/// version of this comment claimed "`!` inside the TUI is the way out to a
/// shell", which the terminal app's own README contradicts: it lists "no local
/// `!` shell mode" among what the TUI does not provide. Exiting the TUI gets a
/// fresh harness session, not a shell; work that needs a shell goes through the
/// agent's own shell tool.
- (void)handOffToTerminal {
    if (self.handedOff)
        return;
    self.handedOff = YES;

    [self.typewriter invalidate];
    self.typewriter = nil;

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

    // The terminal owns the screen now; drop the launch furniture (and its
    // animations) instead of leaving them rendering underneath the web view.
    [self.launchStack removeFromSuperview];
    [self.background removeAllAnimations];
    self.terminalVC = vc;
    [DSHHarness.shared.log append:@"[dsh-ios] CLI front end started"];
}

@end
