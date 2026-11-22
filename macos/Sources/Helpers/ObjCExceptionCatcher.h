#import <Foundation/Foundation.h>

/// This file contains wrappers around various ObjC functions so we can catch
/// exceptions, since you can't natively catch ObjC exceptions from Swift
/// (at least at the time of writing this comment).

/// NSWindow.addTabbedWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyAddTabbedWindowSafely(
    id _Nonnull parent,
    id _Nonnull child,
    NSInteger ordered,
    NSError * _Nullable * _Nullable error
);

/// NSWindowController.showWindow wrapper
FOUNDATION_EXPORT BOOL GhosttyShowWindowSafely(
    id _Nonnull controller,
    id _Nullable sender,
    NSError * _Nullable * _Nullable error
);

@class NSFont;

/// A system font for the Ghostty X chrome, with the result declared nullable.
///
/// AppKit declares these calls as never returning nil, so Swift does not check what
/// comes back and would pass a nil straight into a label's attributes, where Core Text
/// raises from inside a draw call and the app ends. Going through here makes Swift
/// handle a nil (see `SignalFont` in TabBarSettings.swift for the crash this guards).
///
/// `kind`: 0 system, 1 monospaced, 2 system with monospaced digits, 3 title bar (which
/// ignores `weight`).
FOUNDATION_EXPORT NSFont * _Nullable GhosttyChromeFont(
    NSInteger kind,
    CGFloat size,
    CGFloat weight
);
