// OCR accuracy test: renders strips of text the size of a screen capture in different
// styles, points at every English word and checks that WordPopOCR reads that word.
// Built and run by tests/run.sh; exits 1 if fewer than 99% of the words are read right.
#define main wordpop_ocr_main
#include "../mac/ocr.m"
#undef main
#import <Cocoa/Cocoa.h>

typedef struct {
    const char *name;
    CGFloat scale;  // pixels per point: 2 on Retina displays, 1 on most external ones
    CGFloat size;   // font size in points
    BOOL serif, dark, subtitle, edge, twoLines, mixed;
} Scenario;

static const Scenario kScenarios[] = {
    {"13pt text", 2, 13},
    {"11pt small grey text", 2, 11},
    {"20pt large text", 2, 20},
    {"15pt serif", 2, 15, .serif = YES},
    {"13pt dark mode", 2, 13, .dark = YES},
    {"18pt video subtitle", 2, 18, .subtitle = YES},
    {"13pt on a 1x display", 1, 13},
    {"pointer at a word's edge", 2, 13, .edge = YES},
    {"second of two lines", 2, 13, .twoLines = YES},
    {"Chinese with English", 2, 13, .mixed = YES},
    {"Chinese with English, dark", 2, 14, .dark = YES, .mixed = YES},
};

static NSString *Clean(NSString *word) {
    NSMutableCharacterSet *edges = [NSMutableCharacterSet punctuationCharacterSet];
    [edges formUnionWithCharacterSet:NSCharacterSet.whitespaceCharacterSet];
    return [[word stringByTrimmingCharactersInSet:edges] lowercaseString];
}

static BOOL IsASCII(NSString *word) {
    return [word rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithRange:NSMakeRange(0, 128)] invertedSet]].location == NSNotFound;
}

int main(void) {
    @autoreleasepool {
        NSArray *english = @[ @"Researchers observed that soils rich in organic matter retain moisture.",
                              @"The ubiquitous smartphone has fundamentally altered communication habits.",
                              @"Her argument was compelling, yet the evidence remained ambiguous." ];
        NSArray *mixed = @[ @"推荐recommend这个方法，因为它更robust且efficient。",
                            @"这篇paper的methodology很novel，结果significant。",
                            @"请把document发给我，我们meeting再讨论details。" ];
        int right = 0, total = 0;
        double totalTime = 0;
        for (size_t i = 0; i < sizeof kScenarios / sizeof *kScenarios; i++) {
            Scenario scenario = kScenarios[i];
            int scenarioRight = 0, scenarioTotal = 0;
            double scenarioTime = 0;
            NSMutableArray *misses = [NSMutableArray array];
            for (NSString *sentence in scenario.mixed ? mixed : english) {
                int width = 640 * scenario.scale, height = 96 * scenario.scale;
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                if (scenario.subtitle) {  // a busy, colourful video frame
                    srand48(7);
                    for (int r = 0; r < 60; r++) {
                        [[NSColor colorWithHue:drand48() saturation:0.6 brightness:0.3 + 0.5 * drand48() alpha:1] setFill];
                        NSRectFill(NSMakeRect(drand48() * width, drand48() * height, 30 + drand48() * 200, 20 + drand48() * 80));
                    }
                } else {
                    [(scenario.dark ? [NSColor colorWithWhite:0.12 alpha:1] : NSColor.whiteColor) setFill];
                    NSRectFill(NSMakeRect(0, 0, width, height));
                }
                CGFloat points = scenario.size * scenario.scale;
                NSFont *font = scenario.serif ? [NSFont fontWithName:@"Times New Roman" size:points]
                                              : [NSFont systemFontOfSize:points weight:scenario.subtitle ? NSFontWeightBold : NSFontWeightRegular];
                NSColor *color = scenario.dark || scenario.subtitle ? NSColor.whiteColor
                               : scenario.size < 12 ? [NSColor colorWithWhite:0.4 alpha:1] : NSColor.blackColor;
                NSMutableDictionary *attributes = [@{NSFontAttributeName: font, NSForegroundColorAttributeName: color} mutableCopy];
                if (scenario.subtitle) {
                    attributes[NSStrokeColorAttributeName] = NSColor.blackColor;
                    attributes[NSStrokeWidthAttributeName] = @(-4);
                }
                // A capture is a crop of the screen: keep whole words that fit.
                NSString *text = sentence;
                while ([text sizeWithAttributes:attributes].width > width - 20 * scenario.scale) {
                    text = [text substringToIndex:[text rangeOfString:@" " options:NSBackwardsSearch].location];
                }
                CGFloat left = 10 * scenario.scale, lineHeight = font.ascender - font.descender + font.leading;
                CGFloat top = scenario.twoLines ? height / 2.0 + 2 * scenario.scale : (height - lineHeight) / 2;
                if (scenario.twoLines) {
                    [@"Context line above, which should not be picked." drawAtPoint:NSMakePoint(left, height / 2.0 + 2 * scenario.scale)
                                                                       withAttributes:attributes];
                }
                [text drawAtPoint:NSMakePoint(left, height - top - lineHeight) withAttributes:attributes];
                [NSGraphicsContext restoreGraphicsState];

                NSMutableArray *targets = [NSMutableArray array];
                [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByWords
                                      usingBlock:^(NSString *word, NSRange range, NSRange enclosing, BOOL *stop) {
                    if (!IsASCII(word)) return;
                    CGFloat start = left + [[text substringToIndex:range.location] sizeWithAttributes:attributes].width;
                    CGFloat wordWidth = [word sizeWithAttributes:attributes].width;
                    CGFloat x = scenario.edge ? start + wordWidth * 0.12 : start + wordWidth / 2;
                    [targets addObject:@[ word, @(x), @(top + lineHeight * 0.55) ]];
                }];
                for (NSArray *target in targets) {
                    NSString *mode = nil;
                    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                    WPRecognizedWord *read = WPRecognize(rep.CGImage, CGPointMake([target[1] doubleValue], [target[2] doubleValue]),
                                                         scenario.scale, &mode);
                    if (total > 0) scenarioTime += CFAbsoluteTimeGetCurrent() - start;  // the first call loads the model
                    scenarioTotal++;
                    if ([Clean(read.word) isEqualToString:Clean(target[0])]) scenarioRight++;
                    else [misses addObject:[NSString stringWithFormat:@"%@→%@", target[0], read.word ?: @"∅"]];
                    total++;
                }
            }
            right += scenarioRight;
            totalTime += scenarioTime;
            printf("  %-28s %2d/%2d  %4.0f ms  %s\n", scenario.name, scenarioRight, scenarioTotal, scenarioTime * 1000 / scenarioTotal,
                   [[misses componentsJoinedByString:@" "] UTF8String]);
        }
        double accuracy = 100.0 * right / total;
        printf("  %d/%d words read right (%.1f%%), %.0f ms on average\n", right, total, accuracy, totalTime * 1000 / (total - 1));
        return accuracy >= 99 ? 0 : 1;
    }
}
