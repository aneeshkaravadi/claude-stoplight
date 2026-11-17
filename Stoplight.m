// Stoplight: one dot in the menu bar that shows what your Claude Code chats are doing.
//   green  = Claude is working
//   yellow = Claude is waiting on you (a question, a plan to review, an input prompt)
//   red    = nothing is happening
// Hover the dot and it expands into a card listing every open chat and its status.
//
// Status comes from the file Claude Code keeps for each running chat in ~/.claude/sessions
// (chat name plus busy / waiting / idle), and from the end of each chat's transcript, which
// shows whether the last turn asked you something through the next-step box or a question
// card. A message that merely ends in "?" doesn't count. Both are Claude Code internals,
// so a future Claude Code update may need a tweak here.

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>
#include <errno.h>
#include <libproc.h>
#include <signal.h>
#include <string.h>

typedef NS_ENUM(NSInteger, ChatState) { ChatIdle = 0, ChatWorking = 1, ChatWaiting = 2 };

static const CGFloat kPanelWidth = 340;
static const CGFloat kPad = 14;
static const CGFloat kRowsTop = 34;
static const CGFloat kRowHeight = 44;
static const CGFloat kRadius = 18;
static const CGFloat kDotSize = 9;
static const CGFloat kShadowPad = 24;
static const CGFloat kGapBelowMenuBar = 6;
static const NSUInteger kMaxRows = 8;
static const NSTimeInterval kQuestionTTL = 12 * 3600; // a question older than this counts as idle
static const unsigned long long kTailBytes = 256 * 1024;

static NSColor *StateColor(ChatState s) {
    switch (s) {
        case ChatWorking: return [NSColor colorWithSRGBRed:0.19 green:0.82 blue:0.35 alpha:1];
        case ChatWaiting: return [NSColor colorWithSRGBRed:1.00 green:0.78 blue:0.12 alpha:1];
        default: return [NSColor colorWithSRGBRed:1.00 green:0.27 blue:0.23 alpha:1];
    }
}

static NSString *StateWord(ChatState s) {
    switch (s) {
        case ChatWorking: return @"working";
        case ChatWaiting: return @"waiting on you";
        default: return @"idle";
    }
}

static NSString *ShortAgo(NSTimeInterval since) {
    if (since <= 0) return @"";
    NSTimeInterval d = NSDate.date.timeIntervalSince1970 - since;
    if (d < 60) return @"now";
    if (d < 3600) return [NSString stringWithFormat:@"%dm", (int)(d / 60)];
    if (d < 86400) return [NSString stringWithFormat:@"%dh", (int)(d / 3600)];
    return [NSString stringWithFormat:@"%dd", (int)(d / 86400)];
}

static NSString *OneLine(NSString *s) {
    NSArray *parts = [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray *words = [NSMutableArray array];
    for (NSString *p in parts) if (p.length) [words addObject:p];
    return [words componentsJoinedByString:@" "];
}

static NSString *Capitalized(NSString *s) {
    if (!s.length) return s;
    return [[s substringToIndex:1].uppercaseString stringByAppendingString:[s substringFromIndex:1]];
}

static NSTextField *MakeLabel(NSString *s, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:s ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    l.usesSingleLineMode = YES;
    l.maximumNumberOfLines = 1;
    return l;
}

// A rounded rect built from the same path elements at every size, so a spring can morph a
// 9pt dot into the full card.
static CGPathRef CreateRoundRect(CGRect r, CGFloat rad) {
    rad = MIN(rad, MIN(r.size.width, r.size.height) / 2);
    CGFloat k = 0.5523 * rad;
    CGFloat x0 = CGRectGetMinX(r), x1 = CGRectGetMaxX(r), y0 = CGRectGetMinY(r), y1 = CGRectGetMaxY(r);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, x0 + rad, y1);
    CGPathAddLineToPoint(p, NULL, x1 - rad, y1);
    CGPathAddCurveToPoint(p, NULL, x1 - rad + k, y1, x1, y1 - rad + k, x1, y1 - rad);
    CGPathAddLineToPoint(p, NULL, x1, y0 + rad);
    CGPathAddCurveToPoint(p, NULL, x1, y0 + rad - k, x1 - rad + k, y0, x1 - rad, y0);
    CGPathAddLineToPoint(p, NULL, x0 + rad, y0);
    CGPathAddCurveToPoint(p, NULL, x0 + rad - k, y0, x0, y0 + rad - k, x0, y0 + rad);
    CGPathAddLineToPoint(p, NULL, x0, y1 - rad);
    CGPathAddCurveToPoint(p, NULL, x0, y1 - rad + k, x0 + rad - k, y1, x0 + rad, y1);
    CGPathCloseSubpath(p);
    return p;
}

static CABasicAnimation *PulseAnimation(void) {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @1.0;
    a.toValue = @0.35;
    a.duration = 0.9;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    return a;
}

static NSImage *DotImage(NSColor *color) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(14, 14) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSRect d = NSInsetRect(r, (14 - kDotSize) / 2, (14 - kDotSize) / 2);
        [color setFill];
        [[NSBezierPath bezierPathWithOvalInRect:d] fill];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(d, 0.25, 0.25)];
        ring.lineWidth = 0.5;
        [[NSColor colorWithWhite:0 alpha:0.25] setStroke];
        [ring stroke];
        return YES;
    }];
    img.template = NO;
    return img;
}

// Claude Code leaves a session file behind if it crashes, and PIDs get reused, so only count
// files whose process is still alive and still looks like Claude Code.
static BOOL ClaudeProcessAlive(pid_t pid) {
    if (pid <= 0) return NO;
    if (kill(pid, 0) != 0 && errno != EPERM) return NO;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(pid, path, sizeof path) > 0) {
        NSString *exe = [@(path) lastPathComponent].lowercaseString;
        if (![exe containsString:@"claude"] && ![exe isEqual:@"node"] && ![exe isEqual:@"bun"]) return NO;
    }
    return YES;
}

#pragma mark - Model

@interface Chat : NSObject
@property (copy) NSString *sessionId, *name, *detail, *entrypoint;
@property (copy) NSString *hostId; // the desktop app's id for the chat (local_...), if it has one
@property ChatState state;
@property NSTimeInterval since; // when the status last changed (seconds since 1970)
@end
@implementation Chat
@end

// What the latest turn in a transcript is waiting on.
@interface TurnInfo : NSObject
@property (copy) NSString *pending;  // an unanswered question / plan / offer inside a running turn
@property (copy) NSString *ask;      // the question in the turn's next-step box (desktop app)
@end
@implementation TurnInfo
@end

static TurnInfo *ParseTail(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    unsigned long long size = [fh seekToEndOfFile];
    unsigned long long start = size > kTailBytes ? size - kTailBytes : 0;
    [fh seekToFileOffset:start];
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];

    const char *bytes = data.bytes;
    NSUInteger len = data.length, i = 0;
    if (start > 0) { // skip the partial first line
        const char *nl = memchr(bytes, '\n', len);
        if (!nl) return [TurnInfo new];
        i = (NSUInteger)(nl - bytes) + 1;
    }

    NSMutableArray<NSString *> *useIds = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray *> *uses = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *results = [NSMutableSet set];
    NSString *ask = nil;

    while (i < len) {
        const char *nl = memchr(bytes + i, '\n', len - i);
        NSUInteger end = nl ? (NSUInteger)(nl - bytes) : len;
        if (end > i) {
            NSData *line = [NSData dataWithBytesNoCopy:(void *)(bytes + i) length:end - i freeWhenDone:NO];
            NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([entry isKindOfClass:NSDictionary.class] && ![entry[@"isSidechain"] boolValue]) {
                NSString *type = entry[@"type"];
                NSDictionary *message = entry[@"message"];
                id content = [message isKindOfClass:NSDictionary.class] ? message[@"content"] : nil;

                if ([type isEqual:@"user"] && ![entry[@"isMeta"] boolValue]) {
                    BOOL prompt = [content isKindOfClass:NSString.class];
                    if ([content isKindOfClass:NSArray.class]) {
                        BOOL hasResult = NO, hasText = NO;
                        for (NSDictionary *part in content) {
                            if (![part isKindOfClass:NSDictionary.class]) continue;
                            if ([part[@"type"] isEqual:@"tool_result"]) {
                                hasResult = YES;
                                if ([part[@"tool_use_id"] isKindOfClass:NSString.class]) [results addObject:part[@"tool_use_id"]];
                            } else {
                                hasText = YES;
                            }
                        }
                        prompt = hasText && !hasResult;
                    }
                    if (prompt) { // a new turn starts here
                        [useIds removeAllObjects];
                        [uses removeAllObjects];
                        [results removeAllObjects];
                        ask = nil;
                    }
                } else if ([type isEqual:@"assistant"] && [content isKindOfClass:NSArray.class]) {
                    for (NSDictionary *part in content) {
                        if (![part isKindOfClass:NSDictionary.class]) continue;
                        NSString *partType = part[@"type"];
                        if ([partType isEqual:@"tool_use"]) {
                            NSString *uid = part[@"id"], *name = part[@"name"];
                            NSDictionary *input = [part[@"input"] isKindOfClass:NSDictionary.class] ? part[@"input"] : @{};
                            if ([uid isKindOfClass:NSString.class] && [name isKindOfClass:NSString.class]) {
                                [useIds addObject:uid];
                                uses[uid] = @[name, input];
                            }
                            if ([name isEqual:@"mcp__ccd_turn__wrap_up"]) {
                                id a = input[@"ask"];
                                ask = ([a isKindOfClass:NSString.class] && [a length]) ? a : nil;
                            }
                        }
                    }
                }
            }
        }
        i = end + 1;
    }

    TurnInfo *info = [TurnInfo new];
    info.ask = ask;
    for (NSString *uid in useIds) {
        if ([results containsObject:uid]) continue;
        NSString *name = uses[uid][0];
        NSDictionary *input = uses[uid][1];
        if ([name isEqual:@"AskUserQuestion"]) {
            NSArray *qs = input[@"questions"];
            id q = ([qs isKindOfClass:NSArray.class] && qs.count && [qs[0] isKindOfClass:NSDictionary.class]) ? qs[0][@"question"] : nil;
            info.pending = [q isKindOfClass:NSString.class] ? [@"Asks: " stringByAppendingString:q] : @"Asked you a question";
        } else if ([name isEqual:@"ExitPlanMode"]) {
            info.pending = @"Plan is ready for your review";
        } else if ([name isEqual:@"mcp__ccd_session__start_session"] && [input[@"initiation"] isEqual:@"offer"]) {
            info.pending = @"Asks whether to start a new session";
        }
    }
    return info;
}

@interface StatusSource : NSObject
- (NSArray<Chat *> *)load;
@end

@implementation StatusSource {
    NSMutableDictionary<NSString *, NSString *> *_paths; // session id -> transcript path
    NSMutableDictionary<NSString *, NSArray *> *_turns;  // transcript path -> @[signature, TurnInfo]
}

- (instancetype)init {
    if ((self = [super init])) {
        _paths = [NSMutableDictionary dictionary];
        _turns = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)transcriptFor:(NSString *)sessionId {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *cached = _paths[sessionId];
    if (cached && [fm fileExistsAtPath:cached]) return cached;
    NSString *projects = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/projects"];
    NSString *file = [sessionId stringByAppendingPathExtension:@"jsonl"];
    for (NSString *dir in [fm contentsOfDirectoryAtPath:projects error:nil]) {
        NSString *p = [[projects stringByAppendingPathComponent:dir] stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p]) {
            _paths[sessionId] = p;
            return p;
        }
    }
    return nil;
}

- (TurnInfo *)turnFor:(NSString *)sessionId {
    NSString *path = [self transcriptFor:sessionId];
    if (!path) return nil;
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    NSString *sig = [NSString stringWithFormat:@"%f-%llu", attrs.fileModificationDate.timeIntervalSince1970, attrs.fileSize];
    NSArray *hit = _turns[path];
    if (hit && [hit[0] isEqual:sig]) return hit[1];
    TurnInfo *info = ParseTail(path) ?: [TurnInfo new];
    _turns[path] = @[sig, info];
    return info;
}

- (NSArray<Chat *> *)load {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".claude/sessions"];
    NSMutableDictionary<NSString *, Chat *> *byId = [NSMutableDictionary dictionary];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file.pathExtension isEqual:@"json"]) continue;
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]];
        NSDictionary *d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![d isKindOfClass:NSDictionary.class]) continue;
        if ([d[@"spare"] boolValue]) continue; // pre-warmed process with no chat yet
        if (!ClaudeProcessAlive([d[@"pid"] intValue])) continue;

        Chat *c = [Chat new];
        c.sessionId = [d[@"sessionId"] isKindOfClass:NSString.class] ? d[@"sessionId"] : file;
        NSString *cwd = [d[@"cwd"] isKindOfClass:NSString.class] ? d[@"cwd"] : @"";
        NSString *name = [d[@"name"] isKindOfClass:NSString.class] ? d[@"name"] : nil;
        c.name = name.length ? name : (cwd.lastPathComponent.length ? cwd.lastPathComponent : @"Untitled chat");
        c.entrypoint = [d[@"entrypoint"] isKindOfClass:NSString.class] ? d[@"entrypoint"] : @"";
        NSString *host = [d[@"hostSessionId"] isKindOfClass:NSString.class] ? d[@"hostSessionId"] : nil;
        if ([host hasPrefix:@"local_"]) c.hostId = host;
        double ms = [d[@"statusUpdatedAt"] doubleValue];
        if (ms <= 0) ms = [d[@"updatedAt"] doubleValue];
        c.since = ms / 1000.0;

        NSString *status = [d[@"status"] isKindOfClass:NSString.class] ? d[@"status"] : @"idle";
        if ([status isEqual:@"waiting"]) {
            NSString *why = [d[@"waitingFor"] isKindOfClass:NSString.class] ? d[@"waitingFor"] : nil;
            c.state = ChatWaiting;
            c.detail = why.length ? Capitalized(why) : @"Needs your input";
        } else {
            TurnInfo *turn = [self turnFor:c.sessionId];
            if ([status isEqual:@"busy"]) {
                if (turn.pending) {
                    c.state = ChatWaiting;
                    c.detail = turn.pending;
                } else {
                    c.state = ChatWorking;
                    c.detail = @"Working";
                }
            } else {
                BOOL fresh = now - c.since < kQuestionTTL;
                if (fresh && turn.ask) {
                    c.state = ChatWaiting;
                    c.detail = [@"Asks: " stringByAppendingString:turn.ask];
                } else {
                    c.state = ChatIdle;
                    c.detail = @"Idle";
                }
            }
        }
        c.detail = OneLine(c.detail);

        Chat *existing = byId[c.sessionId];
        if (!existing || c.since > existing.since) byId[c.sessionId] = c;
    }

    return [byId.allValues sortedArrayUsingComparator:^NSComparisonResult(Chat *a, Chat *b) {
        if (a.state != b.state) return a.state > b.state ? NSOrderedAscending : NSOrderedDescending;
        if (a.since != b.since) return a.since > b.since ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name];
    }];
}

@end

static NSArray<Chat *> *DemoChats(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSArray *rows = @[
        @[@"Write the lab report", @(ChatWaiting), @"Asks: Should the error analysis use the 95% interval?", @(now - 140)],
        @[@"Fix the login bug", @(ChatWorking), @"Working", @(now - 20)],
        @[@"Refactor the parser", @(ChatWorking), @"Working", @(now - 400)],
        @[@"Plan the spring trip", @(ChatIdle), @"Idle", @(now - 3 * 3600)],
        @[@"Study guide for exam 2", @(ChatIdle), @"Idle", @(now - 2 * 86400)],
    ];
    NSMutableArray *chats = [NSMutableArray array];
    for (NSArray *r in rows) {
        Chat *c = [Chat new];
        c.sessionId = r[0];
        c.name = r[0];
        c.state = [r[1] integerValue];
        c.detail = r[2];
        c.since = [r[3] doubleValue];
        c.entrypoint = @"claude-desktop";
        [chats addObject:c];
    }
    return chats;
}

#pragma mark - Views

@interface Panel : NSPanel
@end
@implementation Panel
- (instancetype)init {
    self = [super initWithContentRect:NSZeroRect
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.opaque = NO;
        self.backgroundColor = NSColor.clearColor;
        self.hasShadow = NO;
        self.level = NSStatusWindowLevel;
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle;
        self.hidesOnDeactivate = NO;
        self.releasedWhenClosed = NO;
        self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
    return self;
}
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }
@end

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface ShapeView : NSView
@end
@implementation ShapeView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        CAShapeLayer *shape = (CAShapeLayer *)self.layer;
        shape.lineWidth = 1;
        shape.shadowColor = NSColor.blackColor.CGColor;
        shape.shadowOpacity = 0.35;
        shape.shadowRadius = 12;
        shape.shadowOffset = CGSizeMake(0, -4);
    }
    return self;
}
- (CALayer *)makeBackingLayer { return [CAShapeLayer layer]; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface DotView : NSView
@end
@implementation DotView
- (instancetype)initWithFrame:(NSRect)frame color:(NSColor *)color pulse:(BOOL)pulse {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = color.CGColor;
        self.layer.cornerRadius = frame.size.width / 2;
        if (pulse) [self.layer addAnimation:PulseAnimation() forKey:@"pulse"];
    }
    return self;
}
@end

@interface RowView : FlippedView
@property (copy) void (^onClick)(void);
@end

@implementation RowView {
    NSTrackingArea *_tracking;
}

- (instancetype)initWithChat:(Chat *)chat width:(CGFloat)width {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, width, kRowHeight)])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10;

        [self addSubview:[[DotView alloc] initWithFrame:NSMakeRect(10, 10, 8, 8)
                                                  color:StateColor(chat.state)
                                                  pulse:chat.state == ChatWorking]];

        NSString *time = chat.state == ChatWorking ? @"" : ShortAgo(chat.since);
        CGFloat timeWidth = time.length ? 40 : 0;

        NSTextField *name = MakeLabel(chat.name, 13, NSFontWeightMedium, [NSColor colorWithWhite:1 alpha:0.95]);
        name.frame = NSMakeRect(26, 5, width - 26 - 10 - timeWidth, 18);
        [self addSubview:name];

        NSColor *detailColor = chat.state == ChatWaiting ? [StateColor(ChatWaiting) colorWithAlphaComponent:0.9]
                                                         : [NSColor colorWithWhite:1 alpha:0.5];
        NSTextField *detail = MakeLabel(chat.detail, 11, NSFontWeightRegular, detailColor);
        detail.frame = NSMakeRect(26, 23, width - 26 - 10, 15);
        [self addSubview:detail];

        if (time.length) {
            NSTextField *t = MakeLabel(time, 11, NSFontWeightRegular, [NSColor colorWithWhite:1 alpha:0.4]);
            t.alignment = NSTextAlignmentRight;
            t.frame = NSMakeRect(width - 10 - timeWidth, 7, timeWidth, 15);
            [self addSubview:t];
        }
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.onClick) self.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.08].CGColor;
}
- (void)mouseExited:(NSEvent *)event { self.layer.backgroundColor = NSColor.clearColor.CGColor; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event {
    if (self.onClick) self.onClick();
}
- (NSView *)hitTest:(NSPoint)point {
    return NSPointInRect([self convertPoint:point fromView:self.superview], self.bounds) ? self : nil;
}
@end

#pragma mark - Controller

@interface Controller : NSObject <NSApplicationDelegate>
@end

@implementation Controller {
    NSStatusItem *_item;
    NSMenu *_menu;
    NSMenuItem *_loginItem;
    Panel *_panel;
    NSView *_container;
    ShapeView *_shapeView;
    FlippedView *_content;
    StatusSource *_source;
    NSArray<Chat *> *_chats;
    NSString *_signature;
    ChatState _light;
    BOOL _hasLight;
    NSRect _panelRect; // the open card, in screen coordinates
    BOOL _open, _pinned, _openPending;
    NSUInteger _generation;
    NSTimer *_refreshTimer, *_hoverTimer;
    NSString *_snapshotPath;
    BOOL _demo;
    id _globalMove, _globalDown;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSArray *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:@"--snapshot"];
    if (i != NSNotFound && i + 1 < args.count) _snapshotPath = args[i + 1];
    _demo = [args containsObject:@"--demo"];
    _source = [StatusSource new];

    _item = [NSStatusBar.systemStatusBar statusItemWithLength:24];
    _item.autosaveName = @"StoplightDot";
    _item.button.imagePosition = NSImageOnly;
    _item.button.target = self;
    _item.button.action = @selector(statusClicked:);
    [_item.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [_item.button addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                               options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                                 owner:self
                                                              userInfo:nil]];

    _menu = [NSMenu new];
    _loginItem = [_menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    _loginItem.target = self;
    [_menu addItem:NSMenuItem.separatorItem];
    [_menu addItemWithTitle:@"Quit Stoplight" action:@selector(terminate:) keyEquivalent:@"q"];

    [self buildPanel];
    [self refresh];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    _refreshTimer.tolerance = 0.25;

    __weak Controller *weakSelf = self;
    _globalMove = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                                         handler:^(NSEvent *e) { [weakSelf mouseMovedGlobally]; }];
    _globalDown = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown
                                                         handler:^(NSEvent *e) { [weakSelf close]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [weakSelf screenChanged]; }];

    if (_snapshotPath) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            Controller *strongSelf = weakSelf;
            strongSelf->_pinned = YES;
            [strongSelf openAnimated:NO];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [strongSelf writeSnapshot];
                [NSApp terminate:nil];
            });
        });
    }
}

- (void)buildPanel {
    _panel = [Panel new];
    _panel.ignoresMouseEvents = YES;
    _container = [[NSView alloc] initWithFrame:NSZeroRect];
    _container.wantsLayer = YES;
    _panel.contentView = _container;

    _shapeView = [[ShapeView alloc] initWithFrame:_container.bounds];
    _shapeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_container addSubview:_shapeView];

    _content = [[FlippedView alloc] initWithFrame:NSZeroRect];
    _content.wantsLayer = YES;
    _content.alphaValue = 0;
    _content.hidden = YES;
    [_container addSubview:_content];
}

#pragma mark Status

- (void)refresh {
    NSArray<Chat *> *chats = _demo ? DemoChats() : [_source load];
    ChatState light = chats.count ? chats[0].state : ChatIdle;
    if (!_hasLight || light != _light) {
        _hasLight = YES;
        _light = light;
        [self updateDot];
    }

    NSMutableString *sig = [NSMutableString string];
    for (Chat *c in chats) [sig appendFormat:@"%@|%ld|%@|%@|%@\n", c.sessionId, (long)c.state, c.name, c.detail, ShortAgo(c.since)];
    if ([sig isEqual:_signature]) return;
    _signature = sig;
    _chats = chats;
    if (_open) {
        [self layoutPanel];
        [self setShapeOpen:YES animated:NO];
    }
}

- (void)updateDot {
    NSStatusBarButton *button = _item.button;
    button.image = DotImage(StateColor(_light));
    button.wantsLayer = YES;
    if (_light == ChatWorking) {
        if (![button.layer animationForKey:@"pulse"]) [button.layer addAnimation:PulseAnimation() forKey:@"pulse"];
    } else {
        [button.layer removeAnimationForKey:@"pulse"];
    }
    button.accessibilityLabel = [NSString stringWithFormat:@"Claude Code is %@", StateWord(_light)];
}

#pragma mark Geometry

- (NSRect)dotRect {
    NSStatusBarButton *b = _item.button;
    NSWindow *w = b.window;
    if (!w) return NSZeroRect;
    return [w convertRectToScreen:[b convertRect:b.bounds toView:nil]];
}

- (NSScreen *)screen { return _item.button.window.screen ?: NSScreen.mainScreen; }

- (CGFloat)menuBarBottom {
    NSWindow *w = _item.button.window;
    if (w) return NSMinY(w.frame);
    return NSMaxY(self.screen.visibleFrame);
}

- (CGFloat)contentHeight {
    NSUInteger rows = MIN(_chats.count, kMaxRows);
    CGFloat body = rows ? rows * kRowHeight : 30;
    if (_chats.count > kMaxRows) body += 20;
    return kRowsTop + body + 8;
}

- (void)layoutPanel {
    NSRect dot = self.dotRect;
    NSRect screen = self.screen.frame;
    CGFloat w = kPanelWidth, h = self.contentHeight;
    CGFloat top = self.menuBarBottom - kGapBelowMenuBar;
    CGFloat x = NSIsEmptyRect(dot) ? NSMaxX(screen) - w - 8 : NSMidX(dot) - w / 2;
    x = MAX(NSMinX(screen) + 8, MIN(x, NSMaxX(screen) - 8 - w));
    _panelRect = NSMakeRect(x, top - h, w, h);
    [_panel setFrame:NSMakeRect(x - kShadowPad, top - h - kShadowPad, w + 2 * kShadowPad, h + kShadowPad + kGapBelowMenuBar)
             display:NO];
    _content.frame = NSMakeRect(kShadowPad, kShadowPad, w, h);
    [self rebuildContent];
}

- (CGPathRef)newOpenPath {
    return CreateRoundRect(CGRectMake(kShadowPad, kShadowPad, NSWidth(_panelRect), NSHeight(_panelRect)), kRadius);
}

- (CGPathRef)newDotPath {
    NSRect dot = self.dotRect;
    CGFloat cx = NSIsEmptyRect(dot) ? NSMidX(_panelRect) : NSMidX(dot);
    cx -= NSMinX(_panel.frame);
    CGFloat top = NSHeight(_panel.frame) - 1;
    return CreateRoundRect(CGRectMake(cx - kDotSize / 2, top - kDotSize, kDotSize, kDotSize), kDotSize / 2);
}

#pragma mark Content

- (void)rebuildContent {
    for (NSView *v in [_content.subviews copy]) [v removeFromSuperview];
    CGFloat w = NSWidth(_content.frame);

    NSTextField *title = MakeLabel(@"Claude Code", 11, NSFontWeightSemibold, [NSColor colorWithWhite:1 alpha:0.5]);
    title.frame = NSMakeRect(kPad + 2, 12, 120, 15);
    [_content addSubview:title];

    NSUInteger counts[3] = {0, 0, 0};
    for (Chat *c in _chats) counts[c.state]++;
    NSMutableArray *bits = [NSMutableArray array];
    if (counts[ChatWaiting]) [bits addObject:[NSString stringWithFormat:@"%lu waiting", (unsigned long)counts[ChatWaiting]]];
    if (counts[ChatWorking]) [bits addObject:[NSString stringWithFormat:@"%lu working", (unsigned long)counts[ChatWorking]]];
    if (counts[ChatIdle]) [bits addObject:[NSString stringWithFormat:@"%lu idle", (unsigned long)counts[ChatIdle]]];
    NSTextField *summary = MakeLabel([bits componentsJoinedByString:@" · "], 11, NSFontWeightRegular, [NSColor colorWithWhite:1 alpha:0.5]);
    summary.alignment = NSTextAlignmentRight;
    summary.frame = NSMakeRect(w - kPad - 2 - 190, 12, 190, 15);
    [_content addSubview:summary];

    if (!_chats.count) {
        NSTextField *empty = MakeLabel(@"No Claude Code chats are open.", 13, NSFontWeightRegular, [NSColor colorWithWhite:1 alpha:0.7]);
        empty.frame = NSMakeRect(kPad + 2, kRowsTop + 6, w - 2 * kPad, 18);
        [_content addSubview:empty];
        return;
    }

    CGFloat y = kRowsTop;
    __weak Controller *weakSelf = self;
    for (NSUInteger i = 0; i < MIN(_chats.count, kMaxRows); i++) {
        Chat *chat = _chats[i];
        RowView *row = [[RowView alloc] initWithChat:chat width:w - 12];
        row.frame = NSMakeRect(6, y, w - 12, kRowHeight);
        NSString *hostId = chat.hostId;
        if (hostId.length) row.onClick = ^{ [weakSelf openChat:hostId]; };
        [_content addSubview:row];
        y += kRowHeight;
    }
    if (_chats.count > kMaxRows) {
        NSString *more = [NSString stringWithFormat:@"+%lu more", (unsigned long)(_chats.count - kMaxRows)];
        NSTextField *label = MakeLabel(more, 11, NSFontWeightRegular, [NSColor colorWithWhite:1 alpha:0.45]);
        label.frame = NSMakeRect(kPad + 2, y + 2, w - 2 * kPad, 15);
        [_content addSubview:label];
    }
}

// The Claude app's own "continue session" link brings it to the front on that chat.
- (void)openChat:(NSString *)hostId {
    [self close];
    NSURLComponents *link = [NSURLComponents componentsWithString:@"claude://code/continue"];
    link.queryItems = @[[NSURLQueryItem queryItemWithName:@"session" value:hostId]];
    if (link.URL) [NSWorkspace.sharedWorkspace openURL:link.URL];
}

#pragma mark Open / close

- (void)setShapeOpen:(BOOL)open animated:(BOOL)animated {
    CAShapeLayer *shape = (CAShapeLayer *)_shapeView.layer;
    CGPathRef dotPath = [self newDotPath], openPath = [self newOpenPath];
    CGPathRef target = open ? openPath : dotPath;
    CGColorRef fill = open ? [NSColor colorWithWhite:0.07 alpha:0.96].CGColor : StateColor(_light).CGColor;
    CGColorRef stroke = open ? [NSColor colorWithWhite:1 alpha:0.12].CGColor : NSColor.clearColor.CGColor;

    if (animated) {
        CAShapeLayer *now = (CAShapeLayer *)shape.presentationLayer;
        CGPathRef from = now.path ?: (open ? dotPath : openPath);
        CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"path"];
        spring.fromValue = (__bridge id)from;
        spring.toValue = (__bridge id)target;
        spring.mass = 1;
        spring.stiffness = open ? 260 : 420;
        spring.damping = open ? 21 : 36;
        spring.duration = spring.settlingDuration;
        [shape addAnimation:spring forKey:@"path"];

        CABasicAnimation *fillAnim = [CABasicAnimation animationWithKeyPath:@"fillColor"];
        fillAnim.fromValue = (__bridge id)(now.fillColor ?: (open ? StateColor(_light).CGColor : fill));
        fillAnim.toValue = (__bridge id)fill;
        fillAnim.duration = open ? 0.18 : 0.26;
        [shape addAnimation:fillAnim forKey:@"fill"];

        CABasicAnimation *strokeAnim = [CABasicAnimation animationWithKeyPath:@"strokeColor"];
        strokeAnim.fromValue = (__bridge id)(now.strokeColor ?: NSColor.clearColor.CGColor);
        strokeAnim.toValue = (__bridge id)stroke;
        strokeAnim.duration = 0.2;
        [shape addAnimation:strokeAnim forKey:@"stroke"];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    shape.path = target;
    shape.fillColor = fill;
    shape.strokeColor = stroke;
    [CATransaction commit];
    CGPathRelease(dotPath);
    CGPathRelease(openPath);
}

- (void)openAnimated:(BOOL)animated {
    _openPending = NO;
    if (_open) return;
    _open = YES;
    NSUInteger generation = ++_generation;
    [self layoutPanel];
    _panel.ignoresMouseEvents = NO;
    if (!_panel.visible) {
        // Start from the dot so the card grows out of it.
        [self setShapeOpen:NO animated:NO];
        [_panel orderFrontRegardless];
    }
    [self setShapeOpen:YES animated:animated];
    _content.hidden = NO;
    if (animated) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
                ctx.duration = 0.18;
                self->_content.animator.alphaValue = 1;
            }];
        });
    } else {
        _content.alphaValue = 1;
    }
    [_hoverTimer invalidate];
    _hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 target:self selector:@selector(checkHover) userInfo:nil repeats:YES];
}

- (void)close {
    _openPending = NO;
    if (!_open) return;
    _open = NO;
    _pinned = NO;
    [_hoverTimer invalidate];
    _hoverTimer = nil;
    NSUInteger generation = ++_generation;
    _panel.ignoresMouseEvents = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.1;
        self->_content.animator.alphaValue = 0;
    }];
    [self setShapeOpen:NO animated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_generation || self->_open) return;
        [self->_panel orderOut:nil];
        self->_content.hidden = YES;
    });
}

- (void)screenChanged {
    if (!_open) return;
    [self layoutPanel];
    [self setShapeOpen:YES animated:NO];
}

#pragma mark Hover and clicks

- (BOOL)mouseOverDot {
    return NSPointInRect(NSEvent.mouseLocation, NSInsetRect(self.dotRect, -2, -2));
}

- (void)scheduleOpen {
    if (_open || _openPending) return;
    _openPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_openPending) return;
        self->_openPending = NO;
        if ([self mouseOverDot]) [self openAnimated:YES];
    });
}

- (void)mouseEntered:(NSEvent *)event { [self scheduleOpen]; }
- (void)mouseExited:(NSEvent *)event {}

- (void)mouseMovedGlobally {
    if (!_open && [self mouseOverDot]) [self scheduleOpen];
}

// While the card is open, close it shortly after the mouse leaves both the dot and the card.
- (void)checkHover {
    static NSTimeInterval leftAt = 0;
    if (!_open) return;
    NSRect zone = NSInsetRect(NSUnionRect(NSInsetRect(self.dotRect, -2, -2), _panelRect), -10, -10);
    if (_pinned || NSPointInRect(NSEvent.mouseLocation, zone)) {
        leftAt = 0;
        return;
    }
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (leftAt == 0) leftAt = now;
    if (now - leftAt >= 0.3) {
        leftAt = 0;
        [self close];
    }
}

- (void)statusClicked:(id)sender {
    NSEvent *e = NSApp.currentEvent;
    if (e.type == NSEventTypeRightMouseUp || (e.modifierFlags & NSEventModifierFlagControl)) {
        [self close];
        _loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        _item.menu = _menu;
        [_item.button performClick:nil];
        _item.menu = nil;
        return;
    }
    if (_open && _pinned) {
        [self close];
        return;
    }
    _pinned = YES;
    [self openAnimated:YES];
}

- (void)toggleLogin:(id)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (service.status == SMAppServiceStatusEnabled) [service unregisterAndReturnError:&error];
    else [service registerAndReturnError:&error];
    if (error) NSLog(@"Open at Login failed: %@", error);
}

#pragma mark Snapshot

- (void)writeSnapshot {
    NSRect bounds = _container.bounds;
    CGFloat scale = _panel.backingScaleFactor ?: 2;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(NSWidth(bounds) * scale) pixelsHigh:(NSInteger)(NSHeight(bounds) * scale)
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bytesPerRow:0 bitsPerPixel:0];
    CGContextRef context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    CGContextScaleCTM(context, scale, scale);
    CGContextSetRGBFillColor(context, 0.45, 0.5, 0.58, 1); // stand-in for a wallpaper
    CGContextFillRect(context, bounds);
    [_container displayIfNeeded];
    [_container.layer renderInContext:context];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:_snapshotPath atomically:YES];
    NSLog(@"open=%d dot=%@ panel=%@ card=%@ chats=%lu light=%@", _open, NSStringFromRect(self.dotRect), NSStringFromRect(_panel.frame),
          NSStringFromRect(_panelRect), (unsigned long)_chats.count, StateWord(_light));
    for (Chat *c in _chats) NSLog(@"  [%@] %@ — %@ (%@)", StateWord(c.state), c.name, c.detail, ShortAgo(c.since));
}

@end

static NSString *LoginStatusWord(SMAppServiceStatus s) {
    switch (s) {
        case SMAppServiceStatusEnabled: return @"on";
        case SMAppServiceStatusRequiresApproval: return @"needs approval in System Settings → General → Login Items";
        case SMAppServiceStatusNotRegistered: return @"off";
        default: return @"not found";
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // `Stoplight --login on|off|status` sets Open at Login without opening the menu.
        NSArray *args = NSProcessInfo.processInfo.arguments;
        NSUInteger i = [args indexOfObject:@"--login"];
        if (i != NSNotFound) {
            NSString *want = i + 1 < args.count ? args[i + 1] : @"status";
            SMAppService *service = SMAppService.mainAppService;
            NSError *error = nil;
            if ([want isEqual:@"on"]) [service registerAndReturnError:&error];
            else if ([want isEqual:@"off"]) [service unregisterAndReturnError:&error];
            if (error) fprintf(stderr, "Open at Login: %s\n", error.localizedDescription.UTF8String);
            printf("Open at Login: %s\n", LoginStatusWord(service.status).UTF8String);
            return error ? 1 : 0;
        }

        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        Controller *controller = [Controller new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
