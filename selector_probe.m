#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static void printClassSelector(Class cls, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    BOOL available = class_getClassMethod(cls, selector) != NULL;
    printf("%s +[%s %s]\n",
           available ? "YES" : "NO ",
           class_getName(cls),
           name.UTF8String);
}

int main(void) {
    @autoreleasepool {
        printClassSelector(NSTouchBar.class,
                           @"presentSystemModalTouchBar:systemTrayItemIdentifier:");
        printClassSelector(NSTouchBar.class,
                           @"dismissSystemModalTouchBar:");
        printClassSelector(NSTouchBarItem.class,
                           @"addSystemTrayItem:");
        printClassSelector(NSTouchBarItem.class,
                           @"removeSystemTrayItem:");
    }
    return 0;
}
