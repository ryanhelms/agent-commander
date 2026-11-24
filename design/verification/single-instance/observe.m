// Read-only probe for the private QA bundle. Window titles and unrelated apps are not reported.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *bundleID = [NSString stringWithUTF8String:argv[1]];
        NSString *bundlePath = [NSString stringWithUTF8String:argv[2]].stringByResolvingSymlinksInPath;
        NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
        NSMutableArray *rows = [NSMutableArray array];
        pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID]) {
            if (app.isTerminated || ![app.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:bundlePath]) continue;
            unsigned int visible = 0;
            for (NSDictionary *window in windows) {
                if ([window[(id)kCGWindowOwnerPID] intValue] != app.processIdentifier || [window[(id)kCGWindowLayer] intValue] != 0) continue;
                CGRect bounds;
                if (CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds)
                    && bounds.size.width >= 650 && bounds.size.height >= 450) visible++;
            }
            [rows addObject:@{@"pid": @(app.processIdentifier), @"active": @(front == app.processIdentifier),
                              @"hidden": @(app.hidden), @"windows": @(visible)}];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
        fwrite(data.bytes, 1, data.length, stdout);
    }
}
