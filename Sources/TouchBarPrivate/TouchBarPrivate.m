#import "TouchBarPrivate.h"
#import <objc/runtime.h>

@interface NSTouchBar (CTPSystemModal)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
         systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

@interface NSTouchBarItem (CTPSystemTray)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

BOOL CTPPrivateTouchBarAvailable(void) {
    return class_getClassMethod(NSTouchBar.class,
                                @selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)) != NULL &&
           class_getClassMethod(NSTouchBar.class,
                                @selector(minimizeSystemModalTouchBar:)) != NULL &&
           class_getClassMethod(NSTouchBar.class,
                                @selector(dismissSystemModalTouchBar:)) != NULL &&
           class_getClassMethod(NSTouchBarItem.class,
                                @selector(addSystemTrayItem:)) != NULL &&
           class_getClassMethod(NSTouchBarItem.class,
                                @selector(removeSystemTrayItem:)) != NULL;
}

void CTPAddSystemTrayItem(NSTouchBarItem *item) {
    [NSTouchBarItem addSystemTrayItem:item];
}

void CTPRemoveSystemTrayItem(NSTouchBarItem *item) {
    [NSTouchBarItem removeSystemTrayItem:item];
}

void CTPPresentSystemModalTouchBar(NSTouchBar *touchBar,
                                  NSTouchBarItemIdentifier trayItemIdentifier) {
    [NSTouchBar presentSystemModalTouchBar:touchBar
                 systemTrayItemIdentifier:trayItemIdentifier];
}

void CTPDismissSystemModalTouchBar(NSTouchBar *touchBar) {
    [NSTouchBar dismissSystemModalTouchBar:touchBar];
}

void CTPMinimizeSystemModalTouchBar(NSTouchBar *touchBar) {
    [NSTouchBar minimizeSystemModalTouchBar:touchBar];
}
