#import <UIKit/UIKit.h>
#import "Headers/YTPlayerViewController.h"

static BOOL YTMURealtimeLyrics(NSString *key) {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [settings[key] boolValue];
}

@interface YTFormattedStringLabel : UILabel
@end

@interface YTMWatchViewController : UIViewController
@property (nonatomic, weak, readwrite) YTPlayerViewController *playerViewController;
@end

static __weak YTPlayerViewController *YTMUObservedPlayer;

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (nonatomic, retain) UITextView *realtimeLyricsView;
@property (nonatomic, retain) CADisplayLink *realtimeLyricsDisplayLink;
@property (nonatomic, retain) NSAttributedString *realtimeLyricsSource;
@property (nonatomic, retain) NSArray *realtimeLyricsSegments;
@property (nonatomic, copy) NSString *realtimeLyricsVideoID;
@property (nonatomic, retain) NSDate *realtimeLyricsLastLoadDate;
@property (nonatomic, assign) BOOL realtimeLyricsUpdating;
- (void)ytmu_updateRealtimeLyrics;
- (void)ytmu_loadRealtimeLyrics;
@end

static YTPlayerViewController *YTMUCurrentPlayer(void) {
    if (YTMUObservedPlayer) return YTMUObservedPlayer;
    Class playerClass = NSClassFromString(@"YTPlayerViewController");
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSMutableArray *pending = [NSMutableArray arrayWithObject:window];
        while (pending.count) {
            UIView *view = pending.lastObject;
            [pending removeLastObject];
            if ([view isKindOfClass:playerClass]) return (YTPlayerViewController *)view;
            [pending addObjectsFromArray:view.subviews];
        }
    }
    return nil;
}

static void YTMUFindTimedArrays(id object, NSMutableArray *result) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [object allValues]) YTMUFindTimedArrays(value, result);
    } else if ([object isKindOfClass:[NSArray class]]) {
        NSArray *array = object;
        BOOL timed = NO;
        for (id item in array) {
            if ([item isKindOfClass:[NSDictionary class]] && [item[@"lyricLine"] isKindOfClass:[NSString class]] && [item[@"cueRange"] isKindOfClass:[NSDictionary class]]) {
                timed = YES;
                break;
            }
        }
        if (timed) [result addObject:array];
        for (id item in array) YTMUFindTimedArrays(item, result);
    }
}

static NSArray *YTMUSegmentsFromTimedJSON(NSDictionary *json) {
    NSMutableArray *arrays = [NSMutableArray array];
    YTMUFindTimedArrays(json, arrays);
    for (NSArray *array in arrays) {
        NSMutableArray *segments = [NSMutableArray array];
        for (NSDictionary *item in array) {
            NSString *text = [item[@"lyricLine"] isKindOfClass:[NSString class]] ? [item[@"lyricLine"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
            NSDictionary *cue = item[@"cueRange"];
            double start = [cue[@"startTimeMilliseconds"] doubleValue] / 1000.0;
            double end = [cue[@"endTimeMilliseconds"] doubleValue] / 1000.0;
            if (end <= start) end = start + 2.5;
            if ([text isEqualToString:@"♪"]) text = @"";
            if (end > start) [segments addObject:@{@"text": text, @"start": @(start), @"end": @(end)}];
        }
        if (segments.count) return segments;
    }
    return nil;
}

static NSArray *YTMUSegmentsFromLRC(NSString *lrc) {
    if (!lrc.length) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{2})(?:\\.(\\d{1,3}))?\\]([^\\r\\n]*)" options:0 error:nil];
    NSArray *matches = [regex matchesInString:lrc options:0 range:NSMakeRange(0, lrc.length)];
    NSMutableArray *segments = [NSMutableArray array];
    for (NSTextCheckingResult *match in matches) {
        double minutes = [[lrc substringWithRange:[match rangeAtIndex:1]] doubleValue];
        double seconds = [[lrc substringWithRange:[match rangeAtIndex:2]] doubleValue];
        NSRange fractionRange = [match rangeAtIndex:3];
        NSString *fraction = fractionRange.location == NSNotFound ? @"" : [lrc substringWithRange:fractionRange];
        double fractionSeconds = fraction.length == 1 ? fraction.doubleValue / 10.0 : fraction.length == 2 ? fraction.doubleValue / 100.0 : fraction.doubleValue / 1000.0;
        double start = minutes * 60.0 + seconds + fractionSeconds;
        NSString *text = [[lrc substringWithRange:[match rangeAtIndex:4]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [segments addObject:@{@"text": text, @"start": @(start), @"end": @(start + 4.0)}];
    }
    for (NSUInteger i = 0; i + 1 < segments.count; i++) {
        NSMutableDictionary *segment = [segments[i] mutableCopy];
        double nextStart = [segments[i + 1][@"start"] doubleValue];
        if (nextStart > [segment[@"start"] doubleValue]) segment[@"end"] = @(nextStart);
        segments[i] = segment;
    }
    return segments.count ? segments : nil;
}

static void YTMUPostJSON(NSString *endpoint, NSDictionary *body, NSDictionary *context, void (^completion)(NSDictionary *, NSError *)) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://music.youtube.com/youtubei/v1/%@?prettyPrint=false", endpoint]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 8.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://music.youtube.com" forHTTPHeaderField:@"Origin"];
    NSMutableDictionary *payload = [body mutableCopy];
    payload[@"context"] = context;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) { completion(nil, error); return; }
        NSError *jsonError = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        completion([json isKindOfClass:[NSDictionary class]] ? json : nil, jsonError);
    }] resume];
}

static void YTMUFetchLRCLib(NSString *title, NSString *artist, double duration, void (^completion)(NSArray *)) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://lrclib.net/api/get"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"track_name" value:title ?: @""],
        [NSURLQueryItem queryItemWithName:@"artist_name" value:artist ?: @""],
        [NSURLQueryItem queryItemWithName:@"duration" value:[NSString stringWithFormat:@"%.0f", duration]]
    ];
    [[[NSURLSession sharedSession] dataTaskWithURL:components.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSArray *segments = YTMUSegmentsFromLRC(json[@"syncedLyrics"]);
        if (segments.count) { completion(segments); return; }

        NSURLComponents *search = [NSURLComponents componentsWithString:@"https://lrclib.net/api/search"];
        search.queryItems = @[
            [NSURLQueryItem queryItemWithName:@"track_name" value:title ?: @""],
            [NSURLQueryItem queryItemWithName:@"artist_name" value:artist ?: @""]
        ];
        [[[NSURLSession sharedSession] dataTaskWithURL:search.URL completionHandler:^(NSData *searchData, NSURLResponse *searchResponse, NSError *searchError) {
            NSArray *results = searchData ? [NSJSONSerialization JSONObjectWithData:searchData options:0 error:nil] : nil;
            for (NSDictionary *result in results) {
                NSArray *found = YTMUSegmentsFromLRC(result[@"syncedLyrics"]);
                if (found.count) { completion(found); return; }
            }
            completion(nil);
        }] resume];
    }] resume];
}

static void YTMULoadSyncedLyrics(NSString *videoID, NSString *title, NSString *artist, double duration, void (^completion)(NSArray *)) {
    if (!videoID.length) { completion(nil); return; }
    NSDictionary *iosContext = @{ @"client": @{ @"clientName": @"IOS", @"clientVersion": @"7.01.05", @"hl": @"en", @"gl": @"US" } };
    YTMUPostJSON(@"next", @{@"videoId": videoID}, iosContext, ^(NSDictionary *nextJSON, NSError *error) {
        __block NSString *browseID = nil;
        void (^scan)(id);
        scan = ^(id object) {
            if (browseID.length) return;
            if ([object isKindOfClass:[NSDictionary class]]) {
                NSDictionary *browse = object[@"browseEndpoint"];
                if ([browse isKindOfClass:[NSDictionary class]] && [browse[@"browseId"] isKindOfClass:[NSString class]] && [browse[@"browseId"] hasPrefix:@"MPLYt_"]) browseID = browse[@"browseId"];
                for (id value in [object allValues]) scan(value);
            } else if ([object isKindOfClass:[NSArray class]]) {
                for (id value in object) scan(value);
            }
        };
        if (!error) scan(nextJSON);
        if (!browseID.length) { YTMUFetchLRCLib(title, artist, duration, completion); return; }
        YTMUPostJSON(@"browse", @{@"browseId": browseID}, iosContext, ^(NSDictionary *browseJSON, NSError *browseError) {
            NSArray *segments = browseError ? nil : YTMUSegmentsFromTimedJSON(browseJSON);
            if (segments.count) { completion(segments); return; }
            YTMUFetchLRCLib(title, artist, duration, completion);
        });
    });
}

static NSAttributedString *YTMUHighlightedLine(NSString *text, double progress, NSDictionary *attributes) {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] initWithString:text attributes:attributes ?: @{}];
    NSUInteger nonWhitespace = 0;
    for (NSUInteger i = 0; i < text.length; i++) if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:i]]) nonWhitespace++;
    NSUInteger played = (NSUInteger)floor(MAX(0.0, MIN(1.0, progress)) * nonWhitespace);
    NSUInteger seen = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        BOOL whitespace = [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:i]];
        BOOL isPlayed = !whitespace && seen < played;
        if (!whitespace) seen++;
        [result addAttribute:NSForegroundColorAttributeName value:(isPlayed ? UIColor.systemPinkColor : UIColor.labelColor) range:NSMakeRange(i, 1)];
        if (isPlayed) [result addAttribute:NSFontAttributeName value:[UIFont boldSystemFontOfSize:16.0] range:NSMakeRange(i, 1)];
    }
    return result;
}

%hook YTMLightweightMusicDescriptionShelfCell
%property (nonatomic, retain) UITextView *realtimeLyricsView;
%property (nonatomic, retain) CADisplayLink *realtimeLyricsDisplayLink;
%property (nonatomic, retain) NSAttributedString *realtimeLyricsSource;
%property (nonatomic, retain) NSArray *realtimeLyricsSegments;
%property (nonatomic, copy) NSString *realtimeLyricsVideoID;
%property (nonatomic, retain) NSDate *realtimeLyricsLastLoadDate;
%property (nonatomic, assign) BOOL realtimeLyricsUpdating;

- (id)initWithFrame:(CGRect)frame {
    self = %orig;
    if (self && YTMURealtimeLyrics(@"YTMUltimateIsEnabled") && YTMURealtimeLyrics(@"realtimeLyrics")) {
        UIView *container = [self valueForKey:@"_descriptionContainer"];
        self.realtimeLyricsView = [[UITextView alloc] init];
        self.realtimeLyricsView.backgroundColor = UIColor.clearColor;
        self.realtimeLyricsView.editable = NO;
        self.realtimeLyricsView.scrollEnabled = NO;
        self.realtimeLyricsView.showsVerticalScrollIndicator = NO;
        [container addSubview:self.realtimeLyricsView];
        self.realtimeLyricsDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(ytmu_updateRealtimeLyrics)];
        self.realtimeLyricsDisplayLink.preferredFramesPerSecond = 15;
        [self.realtimeLyricsDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)setRenderer:(id)renderer {
    %orig;
    if (!YTMURealtimeLyrics(@"YTMUltimateIsEnabled") || !YTMURealtimeLyrics(@"realtimeLyrics")) return;
    YTFormattedStringLabel *lyrics = [self valueForKey:@"_descriptionLabel"];
    lyrics.userInteractionEnabled = YES;
    lyrics.hidden = YES;
    self.realtimeLyricsView.font = lyrics.font;
    self.realtimeLyricsView.textColor = lyrics.textColor;
    self.realtimeLyricsView.attributedText = lyrics.attributedText;
    self.realtimeLyricsSource = lyrics.attributedText;
    YTPlayerViewController *player = YTMUCurrentPlayer();
    NSString *videoID = [player currentVideoID] ?: player.contentVideoID;
    if (![videoID isEqualToString:self.realtimeLyricsVideoID]) {
        self.realtimeLyricsVideoID = videoID;
        self.realtimeLyricsSegments = nil;
        [self ytmu_loadRealtimeLyrics];
    }
}

- (void)layoutSubviews {
    %orig;
    if (YTMURealtimeLyrics(@"YTMUltimateIsEnabled") && YTMURealtimeLyrics(@"realtimeLyrics")) {
        self.realtimeLyricsView.frame = ((UILabel *)[self valueForKey:@"_descriptionLabel"]).frame;
    }
}

- (void)ytmu_loadRealtimeLyrics {
    YTPlayerViewController *player = YTMUCurrentPlayer();
    NSString *videoID = self.realtimeLyricsVideoID;
    if (!player || !videoID.length) return;
    self.realtimeLyricsLastLoadDate = [NSDate date];
    NSString *title = player.playerResponse.playerData.videoDetails.title ?: @"";
    NSString *artist = player.playerResponse.playerData.videoDetails.author ?: @"";
    double duration = player.currentVideoTotalMediaTime;
    YTMULoadSyncedLyrics(videoID, title, artist, duration, ^(NSArray *segments) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([videoID isEqualToString:self.realtimeLyricsVideoID] && segments.count) {
                self.realtimeLyricsSegments = segments;
                NSMutableString *text = [NSMutableString string];
                for (NSDictionary *segment in segments) [text appendFormat:@"%@\n", segment[@"text"]];
                self.realtimeLyricsSource = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: self.realtimeLyricsView.font ?: [UIFont systemFontOfSize:16.0]}];
                [self ytmu_updateRealtimeLyrics];
            }
        });
    });
}

- (void)ytmu_updateRealtimeLyrics {
    if (self.realtimeLyricsUpdating) return;
    self.realtimeLyricsUpdating = YES;
    YTPlayerViewController *player = YTMUCurrentPlayer();
    NSString *videoID = [player currentVideoID] ?: player.contentVideoID;
    if (player && videoID.length && ![videoID isEqualToString:self.realtimeLyricsVideoID]) {
        self.realtimeLyricsVideoID = videoID;
        self.realtimeLyricsSegments = nil;
        self.realtimeLyricsUpdating = NO;
        [self ytmu_loadRealtimeLyrics];
        return;
    }
    if (player && videoID.length && !self.realtimeLyricsSegments.count &&
        (!self.realtimeLyricsLastLoadDate || -[self.realtimeLyricsLastLoadDate timeIntervalSinceNow] > 5.0)) {
        self.realtimeLyricsVideoID = videoID;
        self.realtimeLyricsUpdating = NO;
        [self ytmu_loadRealtimeLyrics];
        return;
    }
    double current = player.currentVideoMediaTime;
    if (!self.realtimeLyricsSegments.count) {
        self.realtimeLyricsView.attributedText = self.realtimeLyricsSource;
        self.realtimeLyricsUpdating = NO;
        return;
    }
    NSMutableAttributedString *output = [[NSMutableAttributedString alloc] initWithString:@""];
    NSDictionary *attributes = @{NSFontAttributeName: self.realtimeLyricsView.font ?: [UIFont systemFontOfSize:16.0]};
    for (NSDictionary *segment in self.realtimeLyricsSegments) {
        double start = [segment[@"start"] doubleValue], end = [segment[@"end"] doubleValue];
        double progress = current < start ? 0.0 : (current >= end ? 1.0 : (current - start) / MAX(0.01, end - start));
        [output appendAttributedString:YTMUHighlightedLine(segment[@"text"], progress, attributes)];
        [output appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attributes]];
    }
    self.realtimeLyricsView.attributedText = output;
    self.realtimeLyricsUpdating = NO;
}

- (void)dealloc {
    [self.realtimeLyricsDisplayLink invalidate];
}
%end

%hook YTMWatchViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    YTMUObservedPlayer = self.playerViewController;
}

- (void)setPlayerViewController:(YTPlayerViewController *)playerViewController {
    %orig;
    YTMUObservedPlayer = playerViewController;
}
%end

%ctor {
    NSMutableDictionary *settings = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"]];
    if (!settings[@"realtimeLyrics"]) {
        settings[@"realtimeLyrics"] = @YES;
        [[NSUserDefaults standardUserDefaults] setObject:settings forKey:@"YTMUltimate"];
    }
}
