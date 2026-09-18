#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <signal.h>

@interface NSTouchBar (SystemModal)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
         systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

@interface NSTouchBarItem (SystemTray)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

static NSTouchBarItemIdentifier const PetItemIdentifier = @"dev.codex.touchbar.pet";
static NSTouchBarItemIdentifier const StatusItemIdentifier = @"dev.codex.touchbar.status";
static NSTouchBarItemIdentifier const TrayItemIdentifier = @"dev.codex.touchbar.tray";

@interface PetController : NSObject <NSTouchBarDelegate>
@property(nonatomic, strong) NSTouchBar *touchBar;
@property(nonatomic, strong) NSCustomTouchBarItem *trayItem;
@property(nonatomic, strong) NSTextField *petLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTimer *animationTimer;
@property(nonatomic, strong) NSTimer *exitTimer;
@property(nonatomic) NSUInteger frameIndex;
@property(nonatomic) BOOL cleanedUp;
@property(nonatomic) NSTimeInterval duration;
@end

@implementation PetController

- (instancetype)initWithDuration:(NSTimeInterval)duration {
    self = [super init];
    if (self) {
        _duration = duration;
    }
    return self;
}

- (void)start {
    self.touchBar = [[NSTouchBar alloc] init];
    self.touchBar.delegate = self;
    self.touchBar.defaultItemIdentifiers = @[PetItemIdentifier, StatusItemIdentifier];
    self.touchBar.principalItemIdentifier = PetItemIdentifier;

    self.trayItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:TrayItemIdentifier];
    NSButton *trayButton = [NSButton buttonWithTitle:@"🐾"
                                             target:self
                                             action:@selector(showTouchBar:)];
    trayButton.bezelColor = [NSColor colorWithCalibratedRed:0.18
                                                      green:0.73
                                                       blue:0.90
                                                      alpha:1.0];
    self.trayItem.view = trayButton;

    [NSTouchBarItem addSystemTrayItem:self.trayItem];
    [NSTouchBar presentSystemModalTouchBar:self.touchBar
                  systemTrayItemIdentifier:TrayItemIdentifier];

    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                           target:self
                                                         selector:@selector(advanceAnimation:)
                                                         userInfo:nil
                                                          repeats:YES];
    self.exitTimer = [NSTimer scheduledTimerWithTimeInterval:self.duration
                                                      target:self
                                                    selector:@selector(finish:)
                                                    userInfo:nil
                                                     repeats:NO];

    printf("TOUCHBAR_POC_RUNNING duration=%.0fs pid=%d\n", self.duration, getpid());
    fflush(stdout);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar
       makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    (void)touchBar;

    if ([identifier isEqualToString:PetItemIdentifier]) {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        self.petLabel = [NSTextField labelWithString:@"ʕ•ᴥ•ʔ"];
        self.petLabel.alignment = NSTextAlignmentCenter;
        self.petLabel.font = [NSFont systemFontOfSize:20.0 weight:NSFontWeightMedium];
        self.petLabel.textColor = [NSColor colorWithCalibratedRed:0.30
                                                           green:0.86
                                                            blue:1.00
                                                           alpha:1.0];
        self.petLabel.toolTip = @"Codex Touch Bar Pet PoC";
        [self.petLabel.widthAnchor constraintEqualToConstant:150.0].active = YES;
        item.view = self.petLabel;
        return item;
    }

    if ([identifier isEqualToString:StatusItemIdentifier]) {
        NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
        self.statusLabel = [NSTextField labelWithString:@"Codex · feasibility test"];
        self.statusLabel.alignment = NSTextAlignmentLeft;
        self.statusLabel.font = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
        self.statusLabel.textColor = NSColor.whiteColor;
        [self.statusLabel.widthAnchor constraintEqualToConstant:310.0].active = YES;
        item.view = self.statusLabel;
        return item;
    }

    return nil;
}

- (void)advanceAnimation:(NSTimer *)timer {
    (void)timer;
    NSArray<NSString *> *frames = @[@"ʕ•ᴥ•ʔ", @"ʕ◕ᴥ◕ʔ", @"ʕᵔᴥᵔʔ", @"ʕ•ᴥ•ʔﾉ"];
    self.frameIndex = (self.frameIndex + 1) % frames.count;
    self.petLabel.stringValue = frames[self.frameIndex];
}

- (void)showTouchBar:(id)sender {
    (void)sender;
    [NSTouchBar presentSystemModalTouchBar:self.touchBar
                  systemTrayItemIdentifier:TrayItemIdentifier];
}

- (void)finish:(id)sender {
    (void)sender;
    [self cleanup];
    [NSApp stop:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSZeroPoint
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0];
        [NSApp postEvent:event atStart:NO];
    });
}

- (void)cleanup {
    if (self.cleanedUp) {
        return;
    }
    self.cleanedUp = YES;
    [self.animationTimer invalidate];
    [self.exitTimer invalidate];
    if (self.touchBar != nil) {
        [NSTouchBar dismissSystemModalTouchBar:self.touchBar];
    }
    if (self.trayItem != nil) {
        [NSTouchBarItem removeSystemTrayItem:self.trayItem];
    }
    printf("TOUCHBAR_POC_CLEANED_UP\n");
    fflush(stdout);
}

- (void)dealloc {
    [self cleanup];
}

@end

static PetController *controller;

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSTimeInterval duration = 45.0;
        if (argc > 1) {
            duration = MAX(5.0, strtod(argv[1], NULL));
        }

        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        controller = [[PetController alloc] initWithDuration:duration];

        signal(SIGINT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t signalInterrupt = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                                   SIGINT,
                                                                   0,
                                                                   dispatch_get_main_queue());
        dispatch_source_t signalTerminate = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                                   SIGTERM,
                                                                   0,
                                                                   dispatch_get_main_queue());
        dispatch_source_set_event_handler(signalInterrupt, ^{
            [controller finish:nil];
        });
        dispatch_source_set_event_handler(signalTerminate, ^{
            [controller finish:nil];
        });
        dispatch_resume(signalInterrupt);
        dispatch_resume(signalTerminate);

        dispatch_async(dispatch_get_main_queue(), ^{
            [controller start];
        });
        [application run];
        [controller cleanup];

        (void)signalInterrupt;
        (void)signalTerminate;
    }
    return 0;
}
