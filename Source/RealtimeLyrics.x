#import <UIKit/UIKit.h>
#import "Headers/YTPlayerViewController.h"

static BOOL YTMURealtimeLyrics(NSString *key) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[key] boolValue];
}

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (nonatomic, retain) UITextView *realtimeLyricsView;
@property (nonatomic, retain) CADisplayLink *realtimeLyricsDisplayLink;
@property (nonatomic, retain) NSAttributedString *realtimeLyricsSource;
@property (nonatomic, assign) BOOL realtimeLyricsUpdating;
- (void)ytmu_updateRealtimeLyrics;
@end

static YTPlayerViewController *YTMUFindPlayerInView(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"YTPlayerViewController")]) {
        return (YTPlayerViewController *)view;
    }
    for (UIView *subview in view.subviews) {
        YTPlayerViewController *player = YTMUFindPlayerInView(subview);
        if (player) return player;
    }
    return nil;
}

static YTPlayerViewController *YTMUCurrentPlayer(void) {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        YTPlayerViewController *player = YTMUFindPlayerInView(window);
        if (player) return player;
    }
    return nil;
}

static NSAttributedString *YTMUHighlightedLyrics(NSAttributedString *source, CGFloat progress) {
    if (!source.length) return source;

    NSMutableAttributedString *result = [source mutableCopy];
    UIColor *baseColor = [UIColor labelColor];
    UIColor *playedColor = [UIColor systemPinkColor];
    NSUInteger visibleCharacters = 0;
    for (NSUInteger i = 0; i < source.length; i++) {
        unichar character = [[source string] characterAtIndex:i];
        if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character]) {
            visibleCharacters++;
        }
    }

    NSUInteger playedCharacters = (NSUInteger)floor(MAX(0.0, MIN(1.0, progress)) * visibleCharacters);
    NSUInteger seenCharacters = 0;
    for (NSUInteger i = 0; i < source.length; i++) {
        unichar character = [[source string] characterAtIndex:i];
        BOOL isWhitespace = [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:character];
        BOOL isPlayed = !isWhitespace && seenCharacters < playedCharacters;
        if (!isWhitespace) seenCharacters++;
        [result addAttribute:NSForegroundColorAttributeName value:(isPlayed ? playedColor : baseColor) range:NSMakeRange(i, 1)];
        if (isPlayed) {
            UIFont *sourceFont = [source attribute:NSFontAttributeName atIndex:i effectiveRange:NULL];
            CGFloat fontSize = sourceFont ? sourceFont.pointSize : 16.0;
            [result addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:fontSize] range:NSMakeRange(i, 1)];
        }
    }
    return result;
}

%hook YTMLightweightMusicDescriptionShelfCell

%property (nonatomic, retain) UITextView *realtimeLyricsView;
%property (nonatomic, retain) CADisplayLink *realtimeLyricsDisplayLink;
%property (nonatomic, retain) NSAttributedString *realtimeLyricsSource;
%property (nonatomic, assign) BOOL realtimeLyricsUpdating;

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self && YTMURealtimeLyrics(@"YTMUltimateIsEnabled") && YTMURealtimeLyrics(@"realtimeLyrics")) {
        UIView *container = [self valueForKey:@"_descriptionContainer"];
        self.realtimeLyricsView = [[UITextView alloc] init];
        self.realtimeLyricsView.backgroundColor = [UIColor clearColor];
        self.realtimeLyricsView.editable = NO;
        self.realtimeLyricsView.scrollEnabled = NO;
        self.realtimeLyricsView.showsVerticalScrollIndicator = NO;
        [container addSubview:self.realtimeLyricsView];
        self.realtimeLyricsDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(ytmu_updateRealtimeLyrics)];
        self.realtimeLyricsDisplayLink.preferredFramesPerSecond = 15;
        [self.realtimeLyricsDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)setRenderer:(id)renderer {
    %orig;
    if (YTMURealtimeLyrics(@"YTMUltimateIsEnabled") && YTMURealtimeLyrics(@"realtimeLyrics")) {
        YTFormattedStringLabel *lyrics = [self valueForKey:@"_descriptionLabel"];
        lyrics.userInteractionEnabled = YES;
        lyrics.hidden = YES;
        self.realtimeLyricsView.font = lyrics.font;
        self.realtimeLyricsView.textColor = lyrics.textColor;
        self.realtimeLyricsView.attributedText = lyrics.attributedText;
        self.realtimeLyricsSource = lyrics.attributedText;
        [self ytmu_updateRealtimeLyrics];
    }
}

- (void)layoutSubviews {
    %orig;
    if (YTMURealtimeLyrics(@"YTMUltimateIsEnabled") && YTMURealtimeLyrics(@"realtimeLyrics")) {
        YTFormattedStringLabel *lyrics = [self valueForKey:@"_descriptionLabel"];
        self.realtimeLyricsView.frame = lyrics.frame;
    }
}

- (void)ytmu_updateRealtimeLyrics {
    if (self.realtimeLyricsUpdating || !self.realtimeLyricsSource.length) return;
    self.realtimeLyricsUpdating = YES;
    YTPlayerViewController *player = YTMUCurrentPlayer();
    CGFloat duration = player.currentVideoTotalMediaTime;
    CGFloat current = player.currentVideoMediaTime;
    if (duration > 0.0 && current >= 0.0 && current <= duration + 1.0) {
        self.realtimeLyricsView.attributedText = YTMUHighlightedLyrics(self.realtimeLyricsSource, current / duration);
    } else {
        self.realtimeLyricsView.attributedText = self.realtimeLyricsSource;
    }
    self.realtimeLyricsUpdating = NO;
}

- (void)dealloc {
    [self.realtimeLyricsDisplayLink invalidate];
}

%end

%ctor {
    if (![[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"][@"realtimeLyrics"]) {
        NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
        settings[@"realtimeLyrics"] = @YES;
        [[NSUserDefaults standardUserDefaults] setObject:settings forKey:@"YTMUltimate"];
    }
}
