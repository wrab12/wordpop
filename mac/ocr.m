// WordPopOCR: reads the word under a point on screen, for 划词查词's ⌥D when nothing is
// selected (text in images, videos, games, remote desktops...). The app starts it on
// demand and talks to it over stdin/stdout, one request per line:
//   in:  "<x> <y> [dump.png]"           a point in global display coordinates (points,
//                                        top-left origin); optionally save the capture
//   out: "<word>\t<x>\t<y>\t<w>\t<h>"   the word and its box, in the same coordinates
//        "-\t<reason>"                  "none", "permission" or "capture"
// Vision's text model takes 40–70 MB once loaded, so it lives in this separate process,
// which quits after kIdleSeconds without a request; the app starts it again when needed.
//
// Test on an image file:  WordPopOCR --image <file.png> <x> <y>   (pixels, top-left origin)

#import <CoreGraphics/CoreGraphics.h>
#import <CoreServices/CoreServices.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <Vision/Vision.h>
#include <dlfcn.h>
#include <poll.h>
#include <unistd.h>

static const int kIdleSeconds = 180;
static const CGSize kCaptureSize = {640, 96};  // points around the pointer: a line or two of text

@interface WPRecognizedWord : NSObject
@property (nonatomic, copy) NSString *word;
@property (nonatomic) CGRect box;  // in pixels of the image, top-left origin
@property (nonatomic) float confidence;
@end

@implementation WPRecognizedWord
@end

#pragma mark - Dictionary check

// Same dictionaries as the app (Oxford English–Chinese, New Oxford American), by handle
// through private DictionaryServices calls looked up at run time.
static NSArray *WPDictionaries(void) {
    static NSArray *dictionaries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFTypeRef (*copyAvailable)(void) = dlsym(RTLD_DEFAULT, "DCSCopyAvailableDictionaries");
        CFStringRef (*identifierOf)(DCSDictionaryRef) = dlsym(RTLD_DEFAULT, "DCSDictionaryGetIdentifier");
        NSMutableArray *found = [NSMutableArray array];
        if (copyAvailable && identifierOf) {
            id available = CFBridgingRelease(copyAvailable());
            NSArray *all = [available isKindOfClass:NSSet.class] ? [available allObjects]
                         : [available isKindOfClass:NSArray.class] ? available : @[];
            for (NSString *wanted in @[ @"com.apple.dictionary.zh_CN-en.OCD", @"com.apple.dictionary.NOAD" ]) {
                for (id dictionary in all) {
                    NSString *identifier = (__bridge NSString *)identifierOf((__bridge DCSDictionaryRef)dictionary);
                    if ([identifier isEqualToString:wanted]) [found addObject:dictionary];
                }
            }
        }
        dictionaries = found;
    });
    return dictionaries;
}

// Whether OCR read a real word: misreadings like "Rcscarchc" or "50ils" are in no dictionary.
static BOOL WPIsWord(NSString *word) {
    NSMutableCharacterSet *edges = [NSMutableCharacterSet punctuationCharacterSet];
    [edges formUnionWithCharacterSet:NSCharacterSet.whitespaceCharacterSet];
    word = [word stringByTrimmingCharactersInSet:edges];
    if (word.length < 2 || [word rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound) return NO;
    BOOL allCaps = [word isEqualToString:word.uppercaseString];
    // Capitals after the first letter mean a misreading ("robustA", which a case-blind
    // lookup would take for "robusta"), unless the whole word is in capitals.
    if (!allCaps && ![[word substringFromIndex:1] isEqualToString:[word substringFromIndex:1].lowercaseString]) return NO;
    for (NSString *candidate in @[ word, word.lowercaseString ]) {
        for (id dictionary in WPDictionaries()) {
            // A lookup also answers for a prefix ("robustA" finds "robust"), so the term
            // the dictionary recognises must span the whole word.
            CFRange term = DCSGetTermRangeInString((__bridge DCSDictionaryRef)dictionary, (__bridge CFStringRef)candidate, 0);
            if (term.location != 0 || term.length != (CFIndex)candidate.length) continue;
            NSString *text = CFBridgingRelease(DCSCopyTextDefinition(
                (__bridge DCSDictionaryRef)dictionary, (__bridge CFStringRef)candidate, CFRangeMake(0, (CFIndex)candidate.length)));
            if (!text) continue;
            // "Thc" is a misreading of "The", not the abbreviation THC.
            NSString *headword = [[text componentsSeparatedByString:@" "].firstObject
                stringByTrimmingCharactersInSet:NSCharacterSet.decimalDigitCharacterSet];
            if (!allCaps && headword.length > 1 && [headword isEqualToString:headword.uppercaseString] &&
                ![headword isEqualToString:headword.lowercaseString]) {
                continue;
            }
            // The New Oxford American still takes "robustA" for "robust": past the headword,
            // only a lowercase ending may follow ("soils" -> "soil" + "s").
            NSString *stem = headword.lowercaseString;
            if (stem.length >= 2 && stem.length < candidate.length && [candidate.lowercaseString hasPrefix:stem]) {
                NSString *ending = [candidate substringFromIndex:stem.length];
                if (ending.length > 4 || ![ending isEqualToString:ending.lowercaseString]) continue;
            }
            return YES;
        }
    }
    return NO;
}

// The real word in what OCR read, allowing for a stray character or two glued on from
// neighbouring text ("robustA" -> "robust", "efficiento" -> "efficient"); nil if none.
static NSString *WPTrimmedWord(NSString *word) {
    for (NSUInteger cut = 1; cut <= 2; cut++) {
        for (NSUInteger head = 0; head <= cut; head++) {  // trailing junk first
            NSUInteger tail = cut - head;
            if (word.length < head + tail + 4) continue;
            NSString *core = [word substringWithRange:NSMakeRange(head, word.length - head - tail)];
            if (WPIsWord(core)) return core;
        }
    }
    return nil;
}

#pragma mark - Recognition

typedef struct {
    CGFloat distance;  // from the point to the word's box, in pixels
    NSUInteger rank;   // which of Vision's candidate readings of the line
    int realness;      // 2: in the dictionary as read, 1: once a stray character is trimmed, 0: not
} WPMatchScore;

static BOOL WPBetter(WPMatchScore a, WPMatchScore b) {
    BOOL aInside = a.distance == 0, bInside = b.distance == 0;
    if (aInside != bInside) return aInside;
    if (a.realness != b.realness) return a.realness > b.realness;
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.distance < b.distance;
}

// The recognised word under (or within half a line height of) the point. With several
// candidate readings of a line (accurate mode), one that gives a real word there wins.
static WPRecognizedWord *WPWordAt(CGImageRef image, CGPoint point, VNRequestTextRecognitionLevel level) {
    CGFloat width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    VNRecognizeTextRequest *request = [VNRecognizeTextRequest new];
    request.recognitionLevel = level;
    request.usesLanguageCorrection = NO;  // we want what is on screen, not a likelier word
    // Fast mode reads Latin script only; the accurate pass also reads Chinese, so an English
    // word inside Chinese text ("推荐recommend") isn't glued to garbled characters.
    request.recognitionLanguages = level == VNRequestTextRecognitionLevelAccurate ? @[ @"zh-Hans", @"en-US" ] : @[ @"en-US" ];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:image options:@{}];
    if (![handler performRequests:@[ request ] error:nil]) return nil;

    __block WPRecognizedWord *best = nil;
    __block WPMatchScore bestScore = {CGFLOAT_MAX, NSUIntegerMax, 0};
    NSUInteger candidates = level == VNRequestTextRecognitionLevelAccurate ? 3 : 1;
    for (VNRecognizedTextObservation *observation in request.results) {
        NSArray<VNRecognizedText *> *readings = [observation topCandidates:candidates];
        for (NSUInteger rank = 0; rank < readings.count; rank++) {
            VNRecognizedText *text = readings[rank];
            [text.string enumerateSubstringsInRange:NSMakeRange(0, text.string.length)
                                            options:NSStringEnumerationByWords
                                         usingBlock:^(NSString *word, NSRange range, NSRange enclosing, BOOL *stop) {
                VNRectangleObservation *wordBox = [text boundingBoxForRange:range error:nil];
                if (!wordBox) return;
                CGRect normalized = wordBox.boundingBox;  // bottom-left origin, 0–1
                CGRect box = CGRectMake(normalized.origin.x * width, (1 - CGRectGetMaxY(normalized)) * height,
                                        normalized.size.width * width, normalized.size.height * height);
                CGFloat dx = MAX(MAX(CGRectGetMinX(box) - point.x, point.x - CGRectGetMaxX(box)), 0);
                CGFloat dy = MAX(MAX(CGRectGetMinY(box) - point.y, point.y - CGRectGetMaxY(box)), 0);
                WPMatchScore score = {hypot(dx, dy), rank, 0};
                if (score.distance > box.size.height * 0.5) return;
                // Trimming only in the accurate pass: from the fast one, "tEcommend" would
                // become "commend" and skip the second look that reads "recommend".
                NSString *real = WPIsWord(word) ? word : level == VNRequestTextRecognitionLevelAccurate ? WPTrimmedWord(word) : nil;
                score.realness = real == word ? 2 : real ? 1 : 0;
                if (!WPBetter(score, bestScore)) return;
                bestScore = score;
                best = [WPRecognizedWord new];
                best.word = real ?: word;
                best.box = box;
                best.confidence = text.confidence;
            }];
        }
    }
    return best;
}

// Small text on 1× displays has too few pixels for Vision: read it at twice the size.
static CGImageRef WPUpscaled(CGImageRef image, CGFloat factor) {
    size_t width = CGImageGetWidth(image) * factor, height = CGImageGetHeight(image) * factor;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return CGImageRetain(image);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGImageRef result = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return result;
}

// Fast recognition takes ~10 ms on a strip this size and is right for ordinary screen
// text. When what it read at the point isn't a real word (outlined video subtitles,
// busy backgrounds), the accurate model (~90 ms) reads it again.
// `pixelsPerPoint` is the capture's scale: 2 on Retina displays, 1 on most external ones.
static WPRecognizedWord *WPRecognize(CGImageRef image, CGPoint point, CGFloat pixelsPerPoint, NSString **mode) {
    CGFloat factor = pixelsPerPoint < 1.5 ? 2 : 1;
    CGImageRef scaled = factor > 1 ? WPUpscaled(image, factor) : CGImageRetain(image);
    CGPoint scaledPoint = CGPointMake(point.x * factor, point.y * factor);
    WPRecognizedWord *word = WPWordAt(scaled, scaledPoint, VNRequestTextRecognitionLevelFast);
    *mode = @"fast";
    if (!word || !WPIsWord(word.word)) {
        WPRecognizedWord *accurate = WPWordAt(scaled, scaledPoint, VNRequestTextRecognitionLevelAccurate);
        if (accurate) {
            word = accurate;
            *mode = @"accurate";
        }
    }
    CGImageRelease(scaled);
    if (word && factor > 1) {
        CGRect box = word.box;
        word.box = CGRectMake(box.origin.x / factor, box.origin.y / factor, box.size.width / factor, box.size.height / factor);
    }
    return word;
}

static CGImageRef WPCapture(CGRect rect, NSString **failure) {
    // Without the permission a capture doesn't fail: other apps' windows are just left
    // out of it. So ask first (this process counts as the app that started it).
    if (!CGPreflightScreenCaptureAccess()) {
        *failure = @"permission";
        return NULL;
    }
    if (@available(macOS 15.2, *)) {
        __block CGImageRef image = NULL;
        __block NSError *error = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [SCScreenshotManager captureImageInRect:rect completionHandler:^(CGImageRef result, NSError *captureError) {
            if (result) image = CGImageRetain(result);
            error = captureError;
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
            *failure = @"capture";
            return NULL;
        }
        if (!image) {
            BOOL declined = [error.domain isEqualToString:SCStreamErrorDomain] && error.code == SCStreamErrorUserDeclined;
            *failure = declined || !CGPreflightScreenCaptureAccess() ? @"permission" : @"capture";
        }
        return image;
    }
    *failure = @"capture";
    return NULL;
}

static void WPSavePNG(CGImageRef image, NSString *path) {
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    if (!destination) return;
    CGImageDestinationAddImage(destination, image, NULL);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
}

// A strip of screen centred on the point, kept within the display it is on.
static CGRect WPCaptureRect(CGPoint point) {
    CGDirectDisplayID display = CGMainDisplayID();
    uint32_t count = 0;
    CGGetDisplaysWithPoint(point, 1, &display, &count);
    CGRect screen = CGDisplayBounds(display);
    CGRect rect = CGRectMake(point.x - kCaptureSize.width / 2, point.y - kCaptureSize.height / 2,
                             kCaptureSize.width, kCaptureSize.height);
    rect.origin.x = MIN(MAX(rect.origin.x, CGRectGetMinX(screen)), CGRectGetMaxX(screen) - rect.size.width);
    rect.origin.y = MIN(MAX(rect.origin.y, CGRectGetMinY(screen)), CGRectGetMaxY(screen) - rect.size.height);
    return CGRectIntersection(rect, screen);
}

static NSString *WPHandle(NSString *request) {
    NSArray<NSString *> *parts = [request componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"-\tnone";
    CGPoint point = CGPointMake(parts[0].doubleValue, parts[1].doubleValue);
    CGRect rect = WPCaptureRect(point);
    NSString *failure = nil;
    CGImageRef image = WPCapture(rect, &failure);
    if (!image) return [@"-\t" stringByAppendingString:failure ?: @"capture"];
    if (parts.count >= 3) WPSavePNG(image, parts[2]);
    CGFloat scale = CGImageGetWidth(image) / rect.size.width;  // 2 on Retina displays
    CGPoint pixel = CGPointMake((point.x - rect.origin.x) * scale, (point.y - rect.origin.y) * scale);
    NSString *mode = nil;
    WPRecognizedWord *word = WPRecognize(image, pixel, scale, &mode);
    CGImageRelease(image);
    if (!word) return @"-\tnone";
    CGRect box = word.box;
    return [NSString stringWithFormat:@"%@\t%.1f\t%.1f\t%.1f\t%.1f\t%@", word.word, rect.origin.x + box.origin.x / scale,
                                      rect.origin.y + box.origin.y / scale, box.size.width / scale, box.size.height / scale, mode];
}

// Reads one line from stdin, waiting at most kIdleSeconds; nil on timeout or EOF.
static NSString *WPReadRequest(void) {
    NSMutableData *line = [NSMutableData data];
    for (;;) {
        struct pollfd input = {STDIN_FILENO, POLLIN, 0};
        if (poll(&input, 1, kIdleSeconds * 1000) <= 0) return nil;
        char c;
        if (read(STDIN_FILENO, &c, 1) != 1) return nil;
        if (c == '\n') return [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
        [line appendBytes:&c length:1];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 5 && strcmp(argv[1], "--image") == 0) {
            CGImageSourceRef source = CGImageSourceCreateWithURL(
                (__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[2])], NULL);
            CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            if (!image) return 1;
            CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
            NSString *mode = nil;
            WPRecognizedWord *word = WPRecognize(image, CGPointMake(atof(argv[3]), atof(argv[4])), 2, &mode);
            printf("%s\t%s\t%.0f ms\n", word.word.UTF8String ?: "-", mode.UTF8String, (CFAbsoluteTimeGetCurrent() - start) * 1000);
            return 0;
        }
    }
    for (;;) {
        @autoreleasepool {
            NSString *request = WPReadRequest();
            if (!request) return 0;  // idle for a while, or the app quit: give the memory back
            NSString *reply = WPHandle(request);
            printf("%s\n", reply.UTF8String);
            fflush(stdout);
        }
    }
}
