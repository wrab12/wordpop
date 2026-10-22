// Draws the app icon and writes mac/AppIcon.icns.
//   clang -fobjc-arc -fmodules -framework Cocoa tools/make_icon.m -o build/make_icon && build/make_icon
// The icon: a word highlighted as if selected, with the dictionary card popping up under
// it; the red underline is how looked-up words are marked.
#import <Cocoa/Cocoa.h>

static void Draw(CGFloat size) {
    CGFloat s = size / 1024.0;  // all coordinates below are on a 1024 canvas
    NSRect body = NSMakeRect(100 * s, 100 * s, 824 * s, 824 * s);
    NSBezierPath *squircle = [NSBezierPath bezierPathWithRoundedRect:body xRadius:186 * s yRadius:186 * s];

    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
    shadow.shadowBlurRadius = 24 * s;
    shadow.shadowOffset = NSMakeSize(0, -10 * s);
    [shadow set];
    [[NSColor blackColor] setFill];
    [squircle fill];
    [NSGraphicsContext restoreGraphicsState];

    NSGradient *background = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.33 green:0.36 blue:0.98 alpha:1]
                                                           endingColor:[NSColor colorWithSRGBRed:0.47 green:0.20 blue:0.88 alpha:1]];
    [background drawInBezierPath:squircle angle:-90];

    // The selected word.
    [[NSColor colorWithWhite:1 alpha:0.30] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(322 * s, 700 * s, 380 * s, 104 * s) xRadius:30 * s yRadius:30 * s] fill];

    // The card, pointing up at the word.
    NSRect card = NSMakeRect(212 * s, 196 * s, 600 * s, 440 * s);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *cardShadow = [NSShadow new];
    cardShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
    cardShadow.shadowBlurRadius = 30 * s;
    cardShadow.shadowOffset = NSMakeSize(0, -12 * s);
    [cardShadow set];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextBeginTransparencyLayer(context, NULL);  // one shadow for card and pointer together
    [[NSColor whiteColor] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:card xRadius:64 * s yRadius:64 * s] fill];
    NSBezierPath *pointer = [NSBezierPath bezierPath];
    [pointer moveToPoint:NSMakePoint(432 * s, 600 * s)];
    [pointer lineToPoint:NSMakePoint(512 * s, 690 * s)];
    [pointer lineToPoint:NSMakePoint(592 * s, 600 * s)];
    [pointer closePath];
    [pointer fill];
    CGContextEndTransparencyLayer(context);
    [NSGraphicsContext restoreGraphicsState];

    NSFont *font = [NSFont fontWithName:@"AvenirNext-Heavy" size:250 * s] ?: [NSFont boldSystemFontOfSize:250 * s];
    NSDictionary *attributes = @{NSFontAttributeName: font,
                                 NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.18 green:0.16 blue:0.45 alpha:1]};
    NSSize text = [@"Aa" sizeWithAttributes:attributes];
    [@"Aa" drawAtPoint:NSMakePoint(NSMidX(card) - text.width / 2, 300 * s) withAttributes:attributes];

    [[NSColor colorWithSRGBRed:1.0 green:0.36 blue:0.33 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(352 * s, 270 * s, 320 * s, 34 * s) xRadius:17 * s yRadius:17 * s] fill];
}

static void Write(CGFloat size, NSString *path) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    Draw(size);
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(void) {
    @autoreleasepool {
        NSString *iconset = @"build/AppIcon.iconset";
        [NSFileManager.defaultManager createDirectoryAtPath:iconset withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSNumber *points in @[ @16, @32, @128, @256, @512 ]) {
            int p = points.intValue;
            Write(p, [NSString stringWithFormat:@"%@/icon_%dx%d.png", iconset, p, p]);
            Write(p * 2, [NSString stringWithFormat:@"%@/icon_%dx%d@2x.png", iconset, p, p]);
        }
        Write(1024, @"build/AppIcon-1024.png");
        return system("iconutil -c icns build/AppIcon.iconset -o mac/AppIcon.icns") == 0 ? 0 : 1;
    }
}
