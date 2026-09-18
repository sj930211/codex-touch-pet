#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

BOOL CTPPrivateTouchBarAvailable(void);
void CTPAddSystemTrayItem(NSTouchBarItem *item);
void CTPRemoveSystemTrayItem(NSTouchBarItem *item);
void CTPPresentSystemModalTouchBar(NSTouchBar *touchBar,
                                  NSTouchBarItemIdentifier trayItemIdentifier);
void CTPMinimizeSystemModalTouchBar(NSTouchBar *touchBar);
void CTPDismissSystemModalTouchBar(NSTouchBar *touchBar);

NS_ASSUME_NONNULL_END
