// WordPop (划词查词): select an English word anywhere on the Mac and its entry from
// the macOS dictionaries (e.g. Oxford English–Chinese) pops up next to it. Every
// word looked up is added to a plain-text vocabulary list, and words already in the
// list show up in red when looked up again, until they are taken off the list.
//
// Triggers: double-clicking a word, or dragging across one, and a tap of ⌘ for whatever is
// selected. How the selection is read depends on the app:
//   - native apps: the Accessibility API (AXSelectedText), off the main thread;
//   - Chromium / Electron / Firefox apps: their accessibility trees are expensive to
//     switch on, so ⌘C is sent instead and the clipboard is put back as it was.
// When a ⌘ tap finds nothing selected, the word under the pointer is read off the
// screen by the WordPopOCR helper (mac/ocr.m), which quits when idle.
// Everything is event-driven: nothing polls or runs while idle.
//
// Written in Objective-C rather than Swift so it builds with nothing but the
// Command Line Tools, whichever Swift/SDK combination they happen to ship.
//
// Preview a popup without the UI:  WordPop --snapshot <word> <out.png> [toggle]

#import <AVFoundation/AVFoundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <ServiceManagement/ServiceManagement.h>
#include <dlfcn.h>
#include <os/log.h>
#include <poll.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }

static void WPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WPLog(NSString *format, ...) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ enabled = [Defaults() boolForKey:@"Debug"]; });
    if (!enabled) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(OS_LOG_DEFAULT, "%{public}@", message);  // NSLog would show the words as <private>
}

#pragma mark - Text helpers

static NSRegularExpression *WPRegex(NSString *pattern) {
    static NSMutableDictionary<NSString *, NSRegularExpression *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    @synchronized(cache) {
        NSRegularExpression *regex = cache[pattern];
        if (!regex) cache[pattern] = regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        return regex;
    }
}

static NSString *WPReplace(NSString *text, NSString *pattern, NSString *replacement) {
    return [WPRegex(pattern) stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:replacement];
}

static NSString *WPFirstMatch(NSString *text, NSString *pattern, NSUInteger group) {
    NSTextCheckingResult *match = [WPRegex(pattern) firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || [match rangeAtIndex:group].location == NSNotFound) return nil;
    return [text substringWithRange:[match rangeAtIndex:group]];
}

// The selection, if it is one English word ("Students'," -> "Students"). With
// allowPhrase (a ⌘ tap), up to four words are accepted.
static NSString *WPCleanWord(NSString *text, BOOL allowPhrase) {
    if (!text.length || text.length > 80) return nil;
    NSMutableCharacterSet *edges = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
    [edges formUnionWithCharacterSet:NSCharacterSet.punctuationCharacterSet];
    [edges formUnionWithCharacterSet:NSCharacterSet.symbolCharacterSet];
    NSString *word = [text stringByTrimmingCharactersInSet:edges];
    word = [word stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    word = WPReplace(word, @"\\s+", @" ");
    NSString *pattern = allowPhrase ? @"^[A-Za-z](?:[A-Za-z'-]*[A-Za-z])?(?: [A-Za-z](?:[A-Za-z'-]*[A-Za-z])?){0,3}$"
                                    : @"^[A-Za-z][A-Za-z'-]*[A-Za-z]$";
    if (word.length > 40 || !WPFirstMatch(word, pattern, 0)) return nil;
    return word;
}

#pragma mark - Dictionary

// One dictionary entry, split into lines for display.
@interface WPEntry : NSObject
@property (nonatomic, copy) NSString *headword;       // "soil" when "soils" was looked up
@property (nonatomic, copy) NSString *pronunciation;  // "BrE sɔɪl, AmE sɔɪl", or nil
@property (nonatomic, copy) NSArray<NSString *> *lines;
@property (nonatomic, strong) WPEntry *see;           // what a bare cross-reference points to ("went" -> "go")
@end

@implementation WPEntry
@end

// DCSCopyTextDefinition(NULL, …) answers from the first active dictionary with any
// hit, and the Apple Dictionary (a glossary of Apple products), listed above Oxford
// English–Chinese, claims words like "personal" and "track". So ask Oxford
// English–Chinese first and then the New Oxford American Dictionary by handle,
// through private DictionaryServices calls looked up at run time in case they go away.
static BOOL gHasOxfordChinese;  // Oxford English–Chinese installed (else definitions are English only)

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
                    if (![identifier isEqualToString:wanted]) continue;
                    [found addObject:dictionary];
                    if ([wanted hasSuffix:@".OCD"]) gHasOxfordChinese = YES;
                }
            }
        }
        dictionaries = found;
    });
    return dictionaries;
}

static NSString *WPDefine(DCSDictionaryRef dictionary, NSString *word) {
    return CFBridgingRelease(DCSCopyTextDefinition(dictionary, (__bridge CFStringRef)word, CFRangeMake(0, (CFIndex)word.length)));
}

// Looks a word up, falling back to simpler spellings ("Paris's" -> "paris's" -> "paris").
static NSString *WPDefinitionText(NSString *word) {
    NSMutableOrderedSet<NSString *> *candidates = [NSMutableOrderedSet orderedSetWithObjects:word, word.lowercaseString, nil];
    NSRange apostrophe = [word rangeOfString:@"'"];
    if (apostrophe.location != NSNotFound && apostrophe.location > 1) {
        [candidates addObject:[word substringToIndex:apostrophe.location].lowercaseString];
    }
    NSArray *dictionaries = WPDictionaries();
    for (id dictionary in dictionaries) {
        for (NSString *candidate in candidates) {
            NSString *text = WPDefine((__bridge DCSDictionaryRef)dictionary, candidate);
            if (text.length) return text;
        }
    }
    if (dictionaries.count) return nil;
    for (NSString *candidate in candidates) {  // neither Oxford dictionary is installed
        NSString *text = WPDefine(NULL, candidate);
        if (text.length) return text;
    }
    return nil;
}

// Entries come back as one long line, e.g.
//   basic | BrE ˈbeɪsɪk, AmE ˈbeɪsɪk | A. adjective ① attributive (fundamental) 基本的 jīběn de ‹principle›▸ honesty is …
// Split it into headword, pronunciation and one line per part of speech (A./B.),
// sense (①②…) and example (▸), dropping the pinyin after Chinese glosses.
static WPEntry *WPParseEntry(NSString *text, NSString *word) {
    WPEntry *entry = [WPEntry new];
    entry.headword = word;
    NSString *body = text;
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@" | "];
    if (parts.count >= 2) {
        // "better 1" -> "better", "natively na·tive·ly" -> "natively"
        entry.headword = WPReplace(WPReplace(parts[0], @"\\s+\\S*·\\S*$", @""), @"\\s*\\d+$", @"");
        NSUInteger bodyStart = 1;
        NSCharacterSet *ipa = [NSCharacterSet characterSetWithCharactersInString:@"ˈˌːəɪʊʌæɒɔɛθðŋʃʒ"];
        if (parts.count >= 3 && ([parts[1] hasPrefix:@"BrE "] || [parts[1] rangeOfCharacterFromSet:ipa].location != NSNotFound)) {
            entry.pronunciation = parts[1];
            bodyStart = 2;
        }
        body = [[parts subarrayWithRange:NSMakeRange(bodyStart, parts.count - bodyStart)] componentsJoinedByString:@" | "];
    }

    NSString *tones = @"āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ";
    NSString *letters = [NSString stringWithFormat:@"[a-zü'%@]", tones];
    NSString *syllables = [NSString stringWithFormat:@"%@*[%@]%@*", letters, tones, letters];
    NSString *pinyin = [NSString stringWithFormat:@"(?<=\\p{Han}) %@(?: (?:%@|de|le|zi|men|ge|me|ne|ba|ma|zhe|guo)\\b)*",
                                                  syllables, syllables];
    body = WPReplace(body, pinyin, @"");
    if (!WPFirstMatch(body, @"\\p{Han}", 0)) {
        // An English dictionary (New Oxford American): "adverb 1 by birth … 2 as … ORIGIN 1754: …"
        body = WPReplace(body, @"\\s+ORIGIN\\s.*$", @"");
        body = WPReplace(body, @"\\s+(?=\\b\\d{1,2} [A-Za-z])", @"\n");
    }
    body = WPReplace(body, @"\\s*(?=\\b[A-H]\\. [a-z])", @"\n");  // A. adjective, B. noun, …
    body = WPReplace(body, @"\\s*(?=[①-⑳])", @"\n");             // senses
    body = WPReplace(body, @"\\s*([▸•])\\s*", @"\n$1 ");           // examples, sub-senses
    body = WPReplace(body, @" {2,}", @" ");
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *raw in [body componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (line.length) [lines addObject:line];
    }
    entry.lines = lines;
    return entry;
}

static WPEntry *WPLookUp(NSString *word) {
    NSString *text = WPDefinitionText(word);
    if (!text) return nil;
    WPEntry *entry = WPParseEntry(text, word);
    // "went | … | past tense → go A, B": show the entry for "go" underneath.
    NSString *body = [entry.lines componentsJoinedByString:@" "];
    if (body.length < 100) {
        NSString *target = WPFirstMatch(body, @"→ ([A-Za-z][A-Za-z'-]*[A-Za-z])", 1);
        if (target && ![target.lowercaseString isEqualToString:entry.headword.lowercaseString]) {
            NSString *seeText = WPDefinitionText(target);
            if (seeText) entry.see = WPParseEntry(seeText, target);
        }
    }
    return entry;
}

// The first few Chinese glosses ("土壤；土地"), for the vocabulary file.
static NSArray<NSString *> *WPGlosses(WPEntry *entry, NSUInteger limit) {
    NSMutableOrderedSet<NSString *> *glosses = [NSMutableOrderedSet orderedSet];
    for (NSString *line in entry.lines) {
        if (glosses.count >= limit) break;
        if ([line hasPrefix:@"▸"] || [line hasPrefix:@"•"]) continue;
        NSString *gloss = WPFirstMatch(line, @"[（(]?\\p{Han}[\\p{Han}（）、·…]*", 0);
        if (gloss) [glosses addObject:gloss];
    }
    return glosses.array;
}

static NSString *WPShortMeaning(WPEntry *entry) {
    NSArray<NSString *> *glosses = WPGlosses(entry, 3);
    NSString *meaning = [glosses componentsJoinedByString:@"；"];
    BOOL english = !WPFirstMatch([entry.lines componentsJoinedByString:@" "], @"\\p{Han}", 0);
    if (english) {
        // The first sense, without part of speech, number or examples:
        // "adverb" / "1 by birth or origin; naturally or originally: crab apple …" -> "by birth or origin; …"
        for (NSString *line in entry.lines) {
            NSString *sense = WPReplace(line, @"^(?:(?:noun|verb|adjective|adverb|exclamation|preposition|conjunction|"
                                              @"pronoun|determiner|abbreviation|prefix|suffix)\\b\\s*)?(?:\\d{1,2} )?", @"");
            sense = [[sense componentsSeparatedByString:@":"].firstObject
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (sense.length < 3 || [sense hasPrefix:@"•"] || [sense hasPrefix:@"▸"]) continue;
            meaning = sense.length > 80 ? [[sense substringToIndex:80] stringByAppendingString:@"…"] : sense;
            break;
        }
    } else if (!glosses.count) {
        meaning = entry.lines.firstObject ?: @"";
        NSArray<NSString *> *seeGlosses = entry.see ? WPGlosses(entry.see, 2) : @[];
        if (seeGlosses.count) meaning = [NSString stringWithFormat:@"%@：%@", meaning, [seeGlosses componentsJoinedByString:@"；"]];
    }
    return WPReplace(meaning, @"\\s+", @" ");
}

#pragma mark - Popup text

static NSColor *WPMarkedColor(void) { return [NSColor colorWithSRGBRed:1.0 green:0.36 blue:0.34 alpha:1]; }
static NSColor *WPLinkColor(void) { return [NSColor colorWithSRGBRed:0.54 green:0.71 blue:0.97 alpha:1]; }

static NSParagraphStyle *WPParagraph(CGFloat indent, CGFloat spacingBefore) {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.firstLineHeadIndent = indent;
    style.headIndent = indent;
    style.paragraphSpacingBefore = spacingBefore;
    style.lineSpacing = 1;
    return style;
}

// "BrE ˈbeɪsɪk, AmE ˈbeɪsɪk" -> "美 /ˈbeɪsɪk/  英 /ˈbeɪsɪk/", American first and brighter.
// Pronunciations without BrE/AmE labels (other dictionaries) are shown as they are.
static NSAttributedString *WPFormatPronunciation(NSString *pronunciation) {
    NSDictionary *us = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.9],
    };
    NSDictionary *other = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.5],
    };
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" ,;"];
    NSRange american = [pronunciation rangeOfString:@"AmE "];
    NSRange british = [pronunciation rangeOfString:@"BrE "];
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    if (american.location == NSNotFound) {
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[@"   " stringByAppendingString:pronunciation]
                                                                       attributes:other]];
        return result;
    }
    NSString *usText = [[pronunciation substringFromIndex:NSMaxRange(american)] stringByTrimmingCharactersInSet:trim];
    [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   美 /%@/", usText]
                                                                   attributes:us]];
    if (british.location != NSNotFound && british.location < american.location) {
        NSRange span = NSMakeRange(NSMaxRange(british), american.location - NSMaxRange(british));
        NSString *ukText = [[pronunciation substringWithRange:span] stringByTrimmingCharactersInSet:trim];
        if (ukText.length && ![ukText isEqualToString:usText]) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"   英 /%@/", ukText]
                                                                           attributes:other]];
        }
    }
    return result;
}

static const NSUInteger kMaxLines = 80;  // "run" and "set" go on for pages

static void WPAppendEntry(NSMutableAttributedString *result, WPEntry *entry, NSColor *headColor, CGFloat headSize) {
    NSDictionary *partStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: WPLinkColor(),
        NSParagraphStyleAttributeName: WPParagraph(0, 8),
    };
    NSDictionary *senseStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.94],
        NSParagraphStyleAttributeName: WPParagraph(0, 5),
    };
    NSDictionary *exampleStyle = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12.5],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.62],
        NSParagraphStyleAttributeName: WPParagraph(14, 2),
    };

    BOOL first = result.length == 0;
    NSMutableAttributedString *header = [[NSMutableAttributedString alloc] initWithString:entry.headword attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:headSize weight:NSFontWeightBold],
        NSForegroundColorAttributeName: headColor,
    }];
    if (entry.pronunciation) [header appendAttributedString:WPFormatPronunciation(entry.pronunciation)];
    NSMutableParagraphStyle *headerStyle = [NSMutableParagraphStyle new];
    headerStyle.tailIndent = -30;  // keep clear of the speaker button in the corner
    headerStyle.paragraphSpacingBefore = first ? 0 : 14;
    [header addAttribute:NSParagraphStyleAttributeName value:headerStyle range:NSMakeRange(0, header.length)];
    if (!first) [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    [result appendAttributedString:header];

    NSUInteger count = 0;
    for (NSString *line in entry.lines) {
        if (++count > kMaxLines) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n…" attributes:exampleStyle]];
            break;
        }
        NSDictionary *style = senseStyle;
        if ([line hasPrefix:@"▸"] || [line hasPrefix:@"•"]) style = exampleStyle;
        else if (WPFirstMatch(line, @"^[A-H]\\. ", 0)) style = partStyle;
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:line]
                                                                       attributes:style]];
    }
}

static NSAttributedString *WPAttributedEntry(WPEntry *entry, BOOL marked) {
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    WPAppendEntry(result, entry, marked ? WPMarkedColor() : NSColor.whiteColor, 19);
    if (entry.see) WPAppendEntry(result, entry.see, [NSColor colorWithWhite:1 alpha:0.9], 16);
    return result;
}

static NSAttributedString *WPMessage(NSString *message) {
    return [[NSAttributedString alloc] initWithString:message attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.75],
        NSParagraphStyleAttributeName: WPParagraph(0, 0),
    }];
}

static NSAttributedString *WPNotFound(NSString *word) {
    return WPMessage([NSString stringWithFormat:@"词典里没有「%@」", word]);
}

#pragma mark - Vocabulary

@interface WPWord : NSObject
@property (nonatomic, copy) NSString *word;     // lowercased
@property (nonatomic, copy) NSString *meaning;
@property (nonatomic, copy) NSString *date;     // first looked up, yyyy-MM-dd
@property (nonatomic) NSInteger count;          // times looked up
@end

@implementation WPWord
@end

// The vocabulary list, a plain-text file with one word per line:
//   soil<TAB>土壤；土地<TAB>2026-10-20<TAB>3
// Only the first column matters; a line with just a word works too, and deleting
// a line takes the word off the list. The file is re-read whenever it changes on disk.
@interface WPVocabulary : NSObject
@property (nonatomic, readonly) NSURL *file;
- (instancetype)initWithFile:(NSURL *)file;
- (NSUInteger)count;
- (WPWord *)wordForForms:(NSArray<NSString *> *)forms;
- (void)addWord:(WPWord *)word;
- (void)removeForms:(NSArray<NSString *> *)forms;
- (void)save;
@end

@implementation WPVocabulary {
    NSMutableArray<WPWord *> *_words;
    NSMutableDictionary<NSString *, WPWord *> *_index;
    NSDate *_fileDate;  // modification date of the file when last read or written
}

- (instancetype)initWithFile:(NSURL *)file {
    self = [super init];
    if (self) _file = file;
    return self;
}

- (NSDate *)modificationDate {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:_file.path error:nil] fileModificationDate];
}

- (void)reloadIfChanged {
    NSDate *modified = [self modificationDate];
    if (_words && (modified == _fileDate || [modified isEqualToDate:_fileDate])) return;
    _fileDate = modified;
    _words = [NSMutableArray array];
    _index = [NSMutableDictionary dictionary];
    NSString *text = [NSString stringWithContentsOfURL:_file encoding:NSUTF8StringEncoding error:nil];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
        WPWord *word = [WPWord new];
        word.word = [fields[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
        if (!word.word.length || _index[word.word]) continue;
        word.meaning = fields.count > 1 ? fields[1] : @"";
        word.date = fields.count > 2 ? fields[2] : @"";
        word.count = MAX(fields.count > 3 ? fields[3].integerValue : 1, 1);
        [_words addObject:word];
        _index[word.word] = word;
    }
}

- (NSUInteger)count {
    [self reloadIfChanged];
    return _words.count;
}

- (WPWord *)wordForForms:(NSArray<NSString *> *)forms {
    [self reloadIfChanged];
    for (NSString *form in forms) {
        WPWord *word = _index[form.lowercaseString];
        if (word) return word;
    }
    return nil;
}

- (void)addWord:(WPWord *)word {
    [self reloadIfChanged];
    if (_index[word.word]) return;
    [_words addObject:word];
    _index[word.word] = word;
    [self save];
}

- (void)removeForms:(NSArray<NSString *> *)forms {
    [self reloadIfChanged];
    BOOL changed = NO;
    for (NSString *form in forms) {
        WPWord *word = _index[form.lowercaseString];
        if (!word) continue;
        [_words removeObject:word];
        [_index removeObjectForKey:word.word];
        changed = YES;
    }
    if (changed) [self save];
}

- (void)save {
    NSMutableString *text = [NSMutableString stringWithString:
        @"# 划词查词 · 生词本　每行：单词⇥释义⇥首次查询⇥查询次数　（删掉一行 = 移出生词本）\n"];
    for (WPWord *word in _words) {
        NSString *meaning = [word.meaning stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
        [text appendFormat:@"%@\t%@\t%@\t%ld\n", word.word, meaning ?: @"", word.date ?: @"", (long)word.count];
    }
    [NSFileManager.defaultManager createDirectoryAtURL:_file.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    [text writeToURL:_file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    _fileDate = [self modificationDate];
}

@end

#pragma mark - Reading the selection

typedef NS_ENUM(NSInteger, WPAppKind) {
    WPAppKindNative,   // read the selection through the Accessibility API
    WPAppKindWeb,      // Chromium, Electron, Firefox: copy it with ⌘C
    WPAppKindIgnored,  // Finder, our own windows, and apps the user turned it off for
};

static WPAppKind WPKindOfBundle(NSURL *bundleURL) {
    if (!bundleURL) return WPAppKindNative;
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *contents = [bundleURL.path stringByAppendingPathComponent:@"Contents"];
    if ([files fileExistsAtPath:[contents stringByAppendingPathComponent:@"MacOS/XUL"]]) return WPAppKindWeb;  // Firefox & co.
    NSString *frameworks = [contents stringByAppendingPathComponent:@"Frameworks"];
    for (NSString *name in [files contentsOfDirectoryAtPath:frameworks error:nil]) {
        if ([name containsString:@"Helper (Renderer)"] || [name isEqualToString:@"Electron Framework.framework"] ||
            [name isEqualToString:@"Chromium Embedded Framework.framework"]) {
            return WPAppKindWeb;
        }
        if ([name hasSuffix:@" Framework.framework"]) {  // Google Chrome / Microsoft Edge / Brave Browser Framework
            NSString *framework = [frameworks stringByAppendingPathComponent:name];
            if ([files fileExistsAtPath:[framework stringByAppendingPathComponent:@"Helpers"]]) return WPAppKindWeb;
        }
    }
    return WPAppKindNative;
}

@interface WPSelection : NSObject
@property (nonatomic, copy) NSString *text;  // nil if the focused element doesn't expose its selection
@property (nonatomic, strong) id element;    // the focused AXUIElement
@property (nonatomic) BOOL hasRange;
@property (nonatomic) CFRange range;
@property (nonatomic) CGRect bounds;         // of the selected text, in global display coordinates; CGRectNull if unknown
- (BOOL)isSameAs:(WPSelection *)other;
@end

@implementation WPSelection

- (BOOL)isSameAs:(WPSelection *)other {
    if (!other || !self.element || !other.element) return NO;
    if (!CFEqual((__bridge CFTypeRef)self.element, (__bridge CFTypeRef)other.element)) return NO;
    if (![(self.text ?: @"") isEqualToString:(other.text ?: @"")]) return NO;
    if (self.hasRange && other.hasRange) {
        return self.range.location == other.range.location && self.range.length == other.range.length;
    }
    return YES;
}

@end

static const float kAXTimeout = 0.25;  // seconds; don't hang on an app that is busy

static WPSelection *WPReadSelection(pid_t pid, BOOL wantBounds) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return nil;
    AXUIElementSetMessagingTimeout(app, kAXTimeout);
    CFTypeRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, &focused);
    CFRelease(app);
    if (error != kAXErrorSuccess || !focused) return nil;
    if (CFGetTypeID(focused) != AXUIElementGetTypeID()) {
        CFRelease(focused);
        return nil;
    }
    AXUIElementRef element = (AXUIElementRef)focused;
    AXUIElementSetMessagingTimeout(element, kAXTimeout);
    WPSelection *selection = [WPSelection new];
    selection.element = CFBridgingRelease(focused);
    selection.bounds = CGRectNull;

    CFTypeRef text = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute, &text) == kAXErrorSuccess && text) {
        if (CFGetTypeID(text) == CFStringGetTypeID()) {
            selection.text = CFBridgingRelease(text);
        } else {
            CFRelease(text);
        }
    }
    CFTypeRef rangeValue = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute, &rangeValue) == kAXErrorSuccess && rangeValue) {
        CFRange range;
        if (CFGetTypeID(rangeValue) == AXValueGetTypeID() && AXValueGetValue(rangeValue, kAXValueTypeCFRange, &range)) {
            selection.hasRange = YES;
            selection.range = range;
            CFTypeRef boundsValue = NULL;
            if (wantBounds && range.length > 0 &&
                AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute, rangeValue,
                                                           &boundsValue) == kAXErrorSuccess && boundsValue) {
                CGRect rect;
                if (CFGetTypeID(boundsValue) == AXValueGetTypeID() && AXValueGetValue(boundsValue, kAXValueTypeCGRect, &rect) &&
                    rect.size.width > 0 && rect.size.height > 0 && rect.size.height < 200) {
                    selection.bounds = rect;
                }
                CFRelease(boundsValue);
            }
        }
        CFRelease(rangeValue);
    }
    return selection;
}

static NSArray<NSPasteboardItem *> *WPSnapshotPasteboard(NSPasteboard *pasteboard) {
    NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
    for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) [copy setData:data forType:type];
        }
        [items addObject:copy];
    }
    return items;
}

// Sends ⌘C to the frontmost app and returns what it copied, leaving the clipboard
// as it was. Returns nil if nothing was selected: the clipboard didn't change within
// timeout milliseconds. A shorter timeout answers sooner; should the copy still land
// after it (slow Electron apps), the clipboard is put back all the same.
static NSString *WPCopySelection(BOOL waitForModifiers, int timeout) {
    // Wait for any modifiers still held to be let go, or ⌘C would arrive as, say, ⌥⌘C (Inspect in Chrome).
    CGEventFlags modifiers = kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl | kCGEventFlagMaskShift;
    for (int i = 0; waitForModifiers && i < 60 && (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & modifiers); i++) {
        usleep(10000);
    }
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    NSInteger before = pasteboard.changeCount;
    NSArray<NSPasteboardItem *> *saved = WPSnapshotPasteboard(pasteboard);

    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (int down = 1; down >= 0; down--) {
        CGEventRef key = CGEventCreateKeyboardEvent(source, kVK_ANSI_C, down);
        CGEventSetFlags(key, kCGEventFlagMaskCommand);
        CGEventPost(kCGSessionEventTap, key);
        CFRelease(key);
    }
    if (source) CFRelease(source);

    NSString *text = nil;
    BOOL changed = NO;
    for (int waited = 0; waited < MAX(timeout, 300) && !text; waited += 5) {  // Electron apps can take a while
        if (!changed && waited >= timeout) break;
        usleep(5000);
        if (pasteboard.changeCount != before) {
            changed = YES;
            text = [pasteboard stringForType:NSPasteboardTypeString];
        }
    }
    if (changed) {
        [pasteboard clearContents];
        if (saved.count) [pasteboard writeObjects:saved];
    } else if (timeout < 500) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (int waited = timeout; waited < 500; waited += 10) {
                usleep(10000);
                if (pasteboard.changeCount == before) continue;
                usleep(30000);  // let the app finish writing
                [pasteboard clearContents];
                if (saved.count) [pasteboard writeObjects:saved];
                WPLog(@"⌘C: late copy, clipboard put back");
                return;
            }
        });
    }
    WPLog(@"⌘C: %@", changed ? [NSString stringWithFormat:@"copied \"%@\"", text] : @"clipboard unchanged");
    return text;
}

// Whether the point (global display coordinates) is in the title bar or tab strip of
// the app's window under it, where double-clicks zoom the window rather than select.
static BOOL WPPointInTitleBar(pid_t pid, CGPoint point) {
    CFArrayRef windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!windows) return NO;
    BOOL result = NO;
    for (NSDictionary *window in (__bridge NSArray *)windows) {
        if ([window[(__bridge NSString *)kCGWindowLayer] integerValue] != 0) continue;
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds)) continue;
        if (!CGRectContainsPoint(bounds, point)) continue;
        result = [window[(__bridge NSString *)kCGWindowOwnerPID] intValue] == pid && point.y - bounds.origin.y < 40;
        break;
    }
    CFRelease(windows);
    return result;
}

#pragma mark - Reading text off the screen

// Talks to the WordPopOCR helper (mac/ocr.m), started on first use. The helper holds
// Vision's text model and quits after a few idle minutes, so the memory comes back; the
// next request starts it again. Requests block, so call these off the main thread.
@interface WPOCRClient : NSObject
// The word under a point (global display coordinates), and its box in the same
// coordinates; nil with a reason ("none", "permission", "capture", "helper").
- (NSString *)wordAt:(CGPoint)point box:(CGRect *)box dumpTo:(NSString *)dump failure:(NSString **)failure;
@end

@implementation WPOCRClient {
    NSTask *_task;
    NSPipe *_input;
    NSPipe *_output;
}

- (BOOL)start {
    NSString *path = [NSBundle.mainBundle pathForAuxiliaryExecutable:@"WordPopOCR"];
    if (!path) return NO;
    _task = [NSTask new];
    _task.executableURL = [NSURL fileURLWithPath:path];
    _input = [NSPipe pipe];
    _output = [NSPipe pipe];
    _task.standardInput = _input;
    _task.standardOutput = _output;
    _task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![_task launchAndReturnError:nil]) {
        _task = nil;
        return NO;
    }
    WPLog(@"OCR helper started (pid %d)", _task.processIdentifier);
    return YES;
}

- (NSString *)readLine:(int)timeoutSeconds {
    int fd = _output.fileHandleForReading.fileDescriptor;
    NSMutableData *line = [NSMutableData data];
    for (;;) {
        struct pollfd output = {fd, POLLIN, 0};
        if (poll(&output, 1, timeoutSeconds * 1000) <= 0) return nil;
        char c;
        if (read(fd, &c, 1) != 1) return nil;  // the helper quit
        if (c == '\n') return [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
        [line appendBytes:&c length:1];
    }
}

- (NSString *)request:(NSString *)line {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    for (int attempt = 0; attempt < 2; attempt++) {  // it may have quit for being idle just now
        if (!_task.running && ![self start]) return nil;
        if (write(_input.fileHandleForWriting.fileDescriptor, data.bytes, data.length) == (ssize_t)data.length) {
            NSString *reply = [self readLine:6];  // first use loads the model and may ask for permission
            if (reply) return reply;
        }
        [_task terminate];
        _task = nil;
    }
    return nil;
}

- (NSString *)wordAt:(CGPoint)point box:(CGRect *)box dumpTo:(NSString *)dump failure:(NSString **)failure {
    NSString *line = [NSString stringWithFormat:@"%.1f %.1f", point.x, point.y];
    if (dump) line = [line stringByAppendingFormat:@" %@", dump];
    NSString *reply = [self request:line];
    NSArray<NSString *> *fields = [reply componentsSeparatedByString:@"\t"];
    if (fields.count < 5) {
        *failure = fields.count == 2 ? fields[1] : @"helper";
        if ([*failure isEqualToString:@"permission"]) {  // a fresh helper picks up the permission once granted
            [_task terminate];
            _task = nil;
        }
        return nil;
    }
    *box = CGRectMake(fields[1].doubleValue, fields[2].doubleValue, fields[3].doubleValue, fields[4].doubleValue);
    WPLog(@"OCR at (%.0f, %.0f): %@ [%@]", point.x, point.y, fields[0], fields.count > 5 ? fields[5] : @"");
    return fields[0];
}

@end

#pragma mark - Popup

@interface WPPanel : NSPanel
@end

@implementation WPPanel

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 300, 60)
                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (self) {
        self.floatingPanel = YES;
        self.level = NSPopUpMenuWindowLevel;
        // Show on every Space, including over full-screen apps.
        self.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                  NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        self.backgroundColor = NSColor.clearColor;
        self.opaque = NO;
        self.hasShadow = YES;
        self.hidesOnDeactivate = NO;
        self.releasedWhenClosed = NO;
        self.animationBehavior = NSWindowAnimationBehaviorNone;
    }
    return self;
}

// Never take keyboard focus away from the app being read.
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }

@end

@interface WPCardView : NSView
@property (nonatomic) CGFloat footerHeight;
@end

@implementation WPCardView

- (void)drawRect:(NSRect)dirtyRect {
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [[NSColor colorWithWhite:0.1 alpha:0.97] setFill];
    [card fill];
    [[NSColor colorWithWhite:1 alpha:0.15] setStroke];
    [card stroke];
    if (self.footerHeight > 0) {
        [[NSColor colorWithWhite:1 alpha:0.08] setFill];
        NSRectFill(NSMakeRect(1, self.footerHeight, NSWidth(self.bounds) - 2, 1));
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

@end

// The panel never becomes key, so buttons must take the very first click.
@interface WPFirstMouseButton : NSButton
@end

@implementation WPFirstMouseButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
@end

static const CGFloat kCardWidth = 380;
static const CGFloat kTextMaxHeight = 300;
static const CGFloat kFooterHeight = 30;
static const NSSize kCardInset = {14, 12};

@interface WPPopup : WPPanel
@property (nonatomic, copy) void (^onToggle)(void);
@property (nonatomic, copy) void (^onSpeak)(void);
// A nil action hides the footer and the speaker button (for "not found").
- (void)setText:(NSAttributedString *)text status:(NSString *)status action:(NSString *)action;
- (void)showNear:(NSRect)anchor;
@end

@implementation WPPopup {
    WPCardView *_card;
    NSScrollView *_scroll;
    NSTextView *_textView;
    NSButton *_speaker;
    NSTextField *_status;
    NSButton *_action;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _card = [[WPCardView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, kTextMaxHeight)];
        _scroll = [[NSScrollView alloc] initWithFrame:_card.bounds];
        _scroll.drawsBackground = NO;
        _scroll.hasVerticalScroller = YES;
        _scroll.autohidesScrollers = YES;
        _scroll.scrollerStyle = NSScrollerStyleOverlay;
        _scroll.scrollerKnobStyle = NSScrollerKnobStyleLight;
        _textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, kCardWidth, kTextMaxHeight)];
        _textView.minSize = NSZeroSize;
        _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
        _textView.verticallyResizable = YES;
        _textView.horizontallyResizable = NO;
        _textView.autoresizingMask = NSViewWidthSizable;
        _textView.textContainer.containerSize = NSMakeSize(kCardWidth, CGFLOAT_MAX);
        _textView.textContainer.widthTracksTextView = YES;
        _textView.textContainer.lineFragmentPadding = 0;
        _textView.textContainerInset = kCardInset;
        _textView.editable = NO;
        _textView.selectable = NO;
        _textView.drawsBackground = NO;
        _scroll.documentView = _textView;
        [_card addSubview:_scroll];

        NSImage *speakerImage = [NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:@"朗读"];
        _speaker = [WPFirstMouseButton buttonWithImage:speakerImage target:self action:@selector(speak)];
        _speaker.bordered = NO;
        _speaker.contentTintColor = [NSColor colorWithWhite:1 alpha:0.75];
        _speaker.toolTip = @"美式发音";
        [_card addSubview:_speaker];

        _status = [NSTextField labelWithString:@""];
        _status.font = [NSFont systemFontOfSize:12];
        _status.textColor = [NSColor colorWithWhite:1 alpha:0.5];
        _status.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_status];

        _action = [WPFirstMouseButton buttonWithTitle:@"" target:self action:@selector(toggle)];
        _action.bordered = NO;
        [_card addSubview:_action];
        self.contentView = _card;
    }
    return self;
}

- (void)speak {
    if (self.onSpeak) self.onSpeak();
}

- (void)toggle {
    if (self.onToggle) self.onToggle();
}

- (void)setText:(NSAttributedString *)text status:(NSString *)status action:(NSString *)action {
    BOOL footer = action != nil;
    CGFloat footerHeight = footer ? kFooterHeight : 0;
    NSPoint topLeft = NSMakePoint(NSMinX(self.frame), NSMaxY(self.frame));

    _textView.frame = NSMakeRect(0, 0, kCardWidth, kTextMaxHeight);
    [_textView.textStorage setAttributedString:text];
    [_textView.layoutManager ensureLayoutForTextContainer:_textView.textContainer];
    CGFloat textHeight = ceil(NSHeight([_textView.layoutManager usedRectForTextContainer:_textView.textContainer]));
    CGFloat scrollHeight = MIN(textHeight + 2 * kCardInset.height + 2, kTextMaxHeight);
    CGFloat height = scrollHeight + footerHeight;

    [self setContentSize:NSMakeSize(kCardWidth, height)];
    [self setFrameTopLeftPoint:topLeft];  // grow or shrink downwards when the text changes in place
    _card.frame = NSMakeRect(0, 0, kCardWidth, height);
    _card.footerHeight = footerHeight;
    _card.needsDisplay = YES;
    _scroll.frame = NSMakeRect(0, footerHeight, kCardWidth, scrollHeight);
    [_textView scrollPoint:NSZeroPoint];

    _speaker.hidden = !footer;
    _speaker.frame = NSMakeRect(kCardWidth - 36, height - 34, 26, 26);
    _status.hidden = !footer;
    _status.stringValue = status ?: @"";
    _status.frame = NSMakeRect(kCardInset.width, 7, kCardWidth - 150, 16);
    _action.hidden = !footer;
    if (footer) {
        _action.attributedTitle = [[NSAttributedString alloc] initWithString:action attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: WPLinkColor(),
        }];
        [_action sizeToFit];
        CGFloat width = NSWidth(_action.frame) + 8;
        _action.frame = NSMakeRect(kCardWidth - 10 - width, 4, width, 22);
    }
}

// Below the word if there's room, otherwise above it.
- (void)showNear:(NSRect)anchor {
    NSPoint center = NSMakePoint(NSMidX(anchor), NSMidY(anchor));
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(center, candidate.frame)) screen = candidate;
    }
    NSRect area = screen.visibleFrame;
    NSSize size = self.frame.size;
    CGFloat x = MIN(MAX(NSMinX(anchor) - kCardInset.width, NSMinX(area) + 6), NSMaxX(area) - size.width - 6);
    CGFloat y = NSMinY(anchor) - 6 - size.height;
    if (y < NSMinY(area) + 6) y = NSMaxY(anchor) + 6;
    y = MIN(MAX(y, NSMinY(area) + 6), NSMaxY(area) - size.height - 6);
    [self setFrameOrigin:NSMakePoint(x, y)];
    [self orderFrontRegardless];
}

- (NSImage *)snapshot {
    NSView *view = self.contentView;
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
    NSImage *image = [[NSImage alloc] initWithSize:view.bounds.size];
    [image addRepresentation:rep];
    return image;
}

@end

#pragma mark - App

typedef NS_ENUM(NSInteger, WPGesture) {
    WPGestureClick,        // only refreshes what we know about the selection
    WPGestureDoubleClick,  // selects a word
    WPGestureDrag,         // may have selected a word
};

// Bumped on every click and ⌘ tap. A lookup still in flight only shows its popup
// if nothing has happened since it started.
static atomic_ulong gRequest;

static NSString *const kHomepage = @"https://github.com/wrab12/wordpop";
static NSString *const kDefaultsAuto = @"AutoLookup";
static NSString *const kDefaultsExcluded = @"ExcludedApps";

@interface WPController : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation WPController {
    WPVocabulary *_vocabulary;
    WPPopup *_popup;
    NSStatusItem *_statusItem;
    dispatch_queue_t _queue;  // reads selections off the main thread, one at a time, in order
    NSMutableDictionary<NSString *, NSNumber *> *_bundleKinds;
    id _dismissMonitor;
    NSTimer *_trustTimer;
    BOOL _trusted;
    NSPoint _downPoint;  // where the last left click went down
    NSTimeInterval _commandDownAt;  // when ⌘ went down on its own, 0 if not
    AVSpeechSynthesizer *_speech;
    WPOCRClient *_ocr;
    dispatch_queue_t _ocrQueue;  // one screen read at a time

    // The word on show.
    WPEntry *_entry;
    WPWord *_word;
    NSArray<NSString *> *_forms;  // the selected spelling and the dictionary headword, lowercased
    BOOL _wasListed;              // already in the list before this lookup: shown in red
    BOOL _listed;                 // in the list now
    pid_t _popupPid;

    // Only touched on _queue.
    WPSelection *_lastSelection;  // last selection read in a native app, to tell new selections from old
    NSString *_lastCopiedWord;    // last word copied out of a web app, likewise
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *path = NSProcessInfo.processInfo.environment[@"WORDPOP_VOCAB"];
        NSURL *file;
        if (path.length) {
            file = [NSURL fileURLWithPath:path.stringByExpandingTildeInPath];
        } else {
            NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                  inDomains:NSUserDomainMask].firstObject;
            file = [support URLByAppendingPathComponent:@"WordPop/生词本.txt"];
        }
        _vocabulary = [[WPVocabulary alloc] initWithFile:file];
        _queue = dispatch_queue_create("wordpop.selection", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        _bundleKinds = [NSMutableDictionary dictionary];
        [Defaults() registerDefaults:@{
            kDefaultsAuto: @YES,
            // Double-clicking identifiers is constant in code editors.
            kDefaultsExcluded: @[ @"com.microsoft.VSCode", @"com.todesktop.230313mzl4w4u92", @"com.apple.dt.Xcode",
                                  @"dev.zed.Zed", @"com.sublimetext.4", @"com.panic.Nova", @"com.jetbrains.pycharm",
                                  @"com.jetbrains.pycharm.ce" ],
        }];
        _popup = [WPPopup new];
        _ocr = [WPOCRClient new];
        _ocrQueue = dispatch_queue_create("wordpop.ocr", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        __weak WPController *weakSelf = self;
        _popup.onToggle = ^{ [weakSelf toggleListed]; };
        _popup.onSpeak = ^{ [weakSelf speak]; };
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    _trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    WPLog(@"accessibility trusted: %d", _trusted);
    if (!_trusted) {
        // Until the user flips the switch in System Settings.
        _trustTimer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(checkTrust) userInfo:nil repeats:YES];
    }
    [self setUpStatusItem];
    [self watchCommandTaps];

    __weak WPController *weakSelf = self;
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
        [weakSelf mouseDown:event];
    }];
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp handler:^(NSEvent *event) {
        [weakSelf mouseUp:event];
    }];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(appActivated:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
                                                         object:nil];

    // Load the dictionary and the fonts now, so the first popup is as quick as the rest.
    dispatch_async(_queue, ^{ WPLookUp(@"hello"); });
    WPPopup *popup = _popup;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        WPEntry *entry = WPLookUp(@"hello");
        if (entry) [popup setText:WPAttributedEntry(entry, NO) status:@"" action:@""];
    });
}

- (void)checkTrust {
    _trusted = AXIsProcessTrusted();
    if (_trusted) {
        WPLog(@"accessibility trusted now");
        [_trustTimer invalidate];
        _trustTimer = nil;
        [self updateStatusIcon];
    }
}

#pragma mark Status item

- (void)setUpStatusItem {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"character.book.closed" accessibilityDescription:@"划词查词"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = @"划词查词";
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    menu.autoenablesItems = NO;
    _statusItem.menu = menu;
    [self updateStatusIcon];
}

- (void)updateStatusIcon {
    _statusItem.button.appearsDisabled = !_trusted || ![Defaults() boolForKey:kDefaultsAuto];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action to:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = action != NULL;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (!_trusted) {
        [self addItem:@"⚠️ 需要开启“辅助功能”权限…" action:@selector(openAccessibilitySettings) to:menu];
        [self addItem:@"已经开启了？点这里重新启动" action:@selector(relaunch) to:menu];
        [menu addItem:NSMenuItem.separatorItem];
    }
    WPDictionaries();
    if (!gHasOxfordChinese) {
        [self addItem:@"⚠️ 没有牛津英汉词典，释义只有英文：去“词典”App 设置里勾选" action:@selector(openDictionaryApp) to:menu];
        [menu addItem:NSMenuItem.separatorItem];
    }
    NSMenuItem *autoItem = [self addItem:@"双击 / 拖选单词时自动查词" action:@selector(toggleAuto) to:menu];
    autoItem.state = [Defaults() boolForKey:kDefaultsAuto] ? NSControlStateValueOn : NSControlStateValueOff;
    // The menu doesn't activate us, so the frontmost app is still the one the user was in.
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front.bundleIdentifier && front.processIdentifier != getpid()) {
        NSString *title = [NSString stringWithFormat:@"在「%@」里也自动查词", front.localizedName ?: front.bundleIdentifier];
        NSMenuItem *appItem = [self addItem:title action:@selector(toggleApp:) to:menu];
        appItem.representedObject = front.bundleIdentifier;
        appItem.state = [self isExcluded:front.bundleIdentifier] ? NSControlStateValueOff : NSControlStateValueOn;
    }
    [self addItem:@"单按一下 ⌘：查选中的词；没选中就识别鼠标下的词" action:NULL to:menu];
    if (!CGPreflightScreenCaptureAccess()) {
        [self addItem:@"⚠️ 识别鼠标下的词需要“屏幕录制”权限…" action:@selector(openScreenRecordingSettings) to:menu];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:[NSString stringWithFormat:@"打开生词本（%lu 个词）", (unsigned long)_vocabulary.count]
           action:@selector(openVocabulary) to:menu];
    [self addItem:@"在访达中显示生词本" action:@selector(revealVocabulary) to:menu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *loginItem = [self addItem:@"开机自动启动" action:@selector(toggleLogin) to:menu];
    loginItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:NSMenuItem.separatorItem];
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    [self addItem:[NSString stringWithFormat:@"关于划词查词 %@", version] action:@selector(openHomepage) to:menu];
    [self addItem:@"检查更新…" action:@selector(openReleases) to:menu];
    [self addItem:@"退出" action:@selector(quit) to:menu];
}

- (void)openHomepage {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:kHomepage]];
}

- (void)openReleases {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:[kHomepage stringByAppendingString:@"/releases"]]];
}

// Dictionary.app → Settings is where Oxford English–Chinese (简体中文-英文) is ticked and downloaded.
- (void)openDictionaryApp {
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:@"/System/Applications/Dictionary.app"]
                                        configuration:[NSWorkspaceOpenConfiguration configuration]
                                    completionHandler:nil];
}

- (BOOL)isExcluded:(NSString *)bundleID {
    return [[Defaults() arrayForKey:kDefaultsExcluded] containsObject:bundleID];
}

- (void)toggleAuto {
    [Defaults() setBool:![Defaults() boolForKey:kDefaultsAuto] forKey:kDefaultsAuto];
    [self updateStatusIcon];
}

- (void)toggleApp:(NSMenuItem *)item {
    NSString *bundleID = item.representedObject;
    NSMutableArray *excluded = [[Defaults() arrayForKey:kDefaultsExcluded] mutableCopy] ?: [NSMutableArray array];
    if ([excluded containsObject:bundleID]) [excluded removeObject:bundleID];
    else [excluded addObject:bundleID];
    [Defaults() setObject:excluded forKey:kDefaultsExcluded];
}

- (void)openAccessibilitySettings {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)ensureVocabularyFile {
    if (![NSFileManager.defaultManager fileExistsAtPath:_vocabulary.file.path]) {
        [_vocabulary count];
        [_vocabulary save];
    }
}

- (void)openVocabulary {
    [self ensureVocabularyFile];
    [NSWorkspace.sharedWorkspace openURL:_vocabulary.file];
}

- (void)revealVocabulary {
    [self ensureVocabularyFile];
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ _vocabulary.file ]];
}

- (void)toggleLogin {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    if (service.status == SMAppServiceStatusEnabled) [service unregisterAndReturnError:&error];
    else [service registerAndReturnError:&error];
    if (error) WPLog(@"login item: %@", error);
    if (service.status == SMAppServiceStatusRequiresApproval) [SMAppService openSystemSettingsLoginItems];
}

- (void)quit {
    [NSApp terminate:nil];
}

- (void)relaunch {
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL
                                        configuration:configuration
                                    completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
    }];
}

#pragma mark Hotkey

// The hotkey is a tap of ⌘ on its own: pressed and let go within kCommandTap seconds
// with no other key, click or scroll in between, so ⌘C, ⌘-click or ⌘Tab never count.
// Watched with a passive global monitor, which sees events without holding them up.
// (RegisterEventHotKey can't be used for a bare modifier, and since macOS 15 it also
// ignores Option-only shortcuts like the ⌥D this used to be.)
static const NSTimeInterval kCommandTap = 0.35;

- (void)watchCommandTaps {
    __weak WPController *weakSelf = self;
    NSEventMask mask = NSEventMaskFlagsChanged | NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                       NSEventMaskOtherMouseDown | NSEventMaskScrollWheel;
    [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
        [weakSelf commandTapEvent:event];
    }];
}

- (void)commandTapEvent:(NSEvent *)event {
    if (event.type != NSEventTypeFlagsChanged) {
        _commandDownAt = 0;  // something else happened while ⌘ was down
        return;
    }
    NSEventModifierFlags held = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                       NSEventModifierFlagControl | NSEventModifierFlagShift);
    if (held == NSEventModifierFlagCommand) {
        if (_commandDownAt == 0) _commandDownAt = event.timestamp;
    } else if (held == 0 && _commandDownAt > 0) {
        if (event.timestamp - _commandDownAt < kCommandTap) [self commandTapped];
        _commandDownAt = 0;
    } else {
        _commandDownAt = 0;  // another modifier joined in
    }
}

- (void)commandTapped {
    unsigned long request = atomic_fetch_add(&gRequest, 1) + 1;
    [self hidePopup];
    if (!_trusted) {
        [self openAccessibilitySettings];
        return;
    }
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t pid = app.processIdentifier;
    BOOL readable = app && pid != getpid();
    BOOL web = readable && [self kindOfApp:app ignoreExclusions:YES] == WPAppKindWeb;
    NSPoint mouse = NSEvent.mouseLocation;
    CGEventRef now = CGEventCreate(NULL);
    CGPoint pointer = CGEventGetLocation(now);  // global display coordinates, like AX bounds
    CFRelease(now);
    WPOCRClient *ocr = _ocr;
    dispatch_queue_t ocrQueue = _ocrQueue;
    dispatch_async(_queue, ^{
        // Nothing selected: read the word under the pointer off the screen.
        __block NSString *screenWord = nil, *failure = nil;
        __block CGRect screenBox = CGRectNull;
        dispatch_group_t screenRead = dispatch_group_create();
        __block BOOL reading = NO;
        void (^readScreen)(void) = ^{
            reading = YES;
            dispatch_group_async(screenRead, ocrQueue, ^{
                NSString *reason = nil;
                CGRect box = CGRectNull;
                screenWord = [ocr wordAt:pointer box:&box dumpTo:nil failure:&reason];
                screenBox = box;
                failure = reason;
            });
        };
        NSString *text = nil;
        CGRect bounds = CGRectNull;
        if (readable) {
            WPSelection *selection = web ? nil : WPReadSelection(pid, YES);
            text = selection.text;
            bounds = selection.bounds;
            if (!text.length && (!selection || !selection.text)) {
                // Only ⌘C can tell whether anything is selected here; read the screen meanwhile.
                readScreen();
                text = WPCopySelection(YES, 150);
            }
        }
        NSString *word = WPCleanWord(text, YES);
        if (!text.length) {
            if (!reading) readScreen();
            dispatch_group_wait(screenRead, DISPATCH_TIME_FOREVER);
            word = WPCleanWord(screenWord, NO);
            bounds = screenBox;
        }
        WPLog(@"⌘ tap in %d: %@", pid, word ?: text ?: screenWord ?: failure);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load(&gRequest) != request) return;
            NSRect anchor = [self anchorForBounds:bounds mouse:mouse];
            if (word) [self lookUp:word anchor:anchor pid:pid explicit:YES];
            else if ([failure isEqualToString:@"permission"]) [self askForScreenRecordingNear:anchor];
        });
    });
}

- (void)askForScreenRecordingNear:(NSRect)anchor {
    _entry = nil;
    [_popup setText:WPMessage(@"没选中文字时，单按 ⌘ 会识别鼠标下面的词，这需要“屏幕录制”权限：\n"
                              @"系统设置 → 隐私与安全性 → 屏幕与系统录音 → 打开“划词查词”。")
             status:nil
             action:nil];
    [self showPopupNear:anchor pid:0];
    if (!CGRequestScreenCaptureAccess()) [self openScreenRecordingSettings];
}

- (void)openScreenRecordingSettings {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
}

#pragma mark Mouse

- (WPAppKind)kindOfApp:(NSRunningApplication *)app ignoreExclusions:(BOOL)ignoreExclusions {
    NSString *bundleID = app.bundleIdentifier ?: @"";
    if (app.processIdentifier == getpid() || [bundleID isEqualToString:@"com.apple.finder"]) return WPAppKindIgnored;
    if (!ignoreExclusions && [self isExcluded:bundleID]) return WPAppKindIgnored;
    // Native apps that draw their own text and don't expose the selection.
    if ([@[ @"com.tencent.xinWeChat" ] containsObject:bundleID]) return WPAppKindWeb;
    NSString *key = app.bundleURL.path ?: bundleID;
    NSNumber *kind = _bundleKinds[key];
    if (!kind) _bundleKinds[key] = kind = @(WPKindOfBundle(app.bundleURL));
    return kind.integerValue;
}

- (void)mouseDown:(NSEvent *)event {
    atomic_fetch_add(&gRequest, 1);
    _downPoint = NSEvent.mouseLocation;
    [self hidePopup];
}

- (void)mouseUp:(NSEvent *)event {
    unsigned long request = atomic_fetch_add(&gRequest, 1) + 1;
    if (!_trusted || ![Defaults() boolForKey:kDefaultsAuto]) return;
    if (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) return;
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    WPAppKind kind = [self kindOfApp:app ignoreExclusions:NO];
    if (!app || kind == WPAppKindIgnored) return;

    NSPoint mouse = NSEvent.mouseLocation;
    CGFloat dx = fabs(mouse.x - _downPoint.x), dy = fabs(mouse.y - _downPoint.y);
    BOOL moved = dx > 3 || dy > 3;
    WPGesture gesture = WPGestureClick;
    if (event.clickCount == 2 && !moved) gesture = WPGestureDoubleClick;
    else if (event.clickCount <= 2 && moved && dy <= 16 && dx <= 400) gesture = WPGestureDrag;  // across a word, not a window
    else if (event.clickCount > 2) return;  // triple clicks select whole lines
    if (kind == WPAppKindWeb && gesture == WPGestureClick) return;

    pid_t pid = app.processIdentifier;
    CGPoint point = CGEventGetLocation(event.CGEvent);  // global display coordinates, like AX bounds
    dispatch_async(_queue, ^{
        NSString *word = nil;
        CGRect bounds = CGRectNull;
        if (kind == WPAppKindWeb) {
            if (WPPointInTitleBar(pid, point)) {
                WPLog(@"double-click in %d: title bar, skipped", pid);
                return;
            }
            if (atomic_load(&gRequest) != request) return;
            word = WPCleanWord(WPCopySelection(NO, 300), NO);
            // Dragging a slider or scrollbar copies whatever was left selected: skip the word just shown.
            if (gesture == WPGestureDrag && [word isEqualToString:self->_lastCopiedWord]) return;
            if (word) self->_lastCopiedWord = word;
        } else {
            WPSelection *selection = WPReadSelection(pid, gesture != WPGestureClick);
            WPSelection *previous = self->_lastSelection;
            self->_lastSelection = selection;
            if (gesture == WPGestureClick) return;
            if (!selection.text.length) {
                WPLog(@"%@ in %d: no selection (%@)", gesture == WPGestureDrag ? @"drag" : @"double-click", pid,
                      selection ? @"empty" : @"not exposed");
                return;
            }
            // Double-clicking a title bar or dragging a window leaves the old selection in
            // place. Where the app tells us where the selection is, it must be under the
            // pointer; otherwise it must have changed since the last click.
            if (!CGRectIsNull(selection.bounds)) {
                if (!CGRectContainsPoint(CGRectInset(selection.bounds, -40, -24), point)) return;
                if (gesture == WPGestureDrag && [selection isSameAs:previous]) return;
            } else if ([selection isSameAs:previous]) {
                return;
            }
            word = WPCleanWord(selection.text, NO);
            bounds = selection.bounds;
        }
        WPLog(@"%@ in %d: %@", gesture == WPGestureDrag ? @"drag" : @"double-click", pid, word);
        if (!word) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (atomic_load(&gRequest) != request) return;
            [self lookUp:word anchor:[self anchorForBounds:bounds mouse:mouse] pid:pid explicit:NO];
        });
    });
}

// The selected word's bounds in Cocoa coordinates, or a word-sized box around the pointer.
- (NSRect)anchorForBounds:(CGRect)bounds mouse:(NSPoint)mouse {
    if (CGRectIsNull(bounds)) return NSMakeRect(mouse.x - 4, mouse.y - 11, 8, 22);
    CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
    return NSMakeRect(bounds.origin.x, top - bounds.origin.y - bounds.size.height, bounds.size.width, bounds.size.height);
}

#pragma mark Popup

- (void)lookUp:(NSString *)selected anchor:(NSRect)anchor pid:(pid_t)pid explicit:(BOOL)explicit {
    WPEntry *entry = WPLookUp(selected);
    if (!entry) {
        if (!explicit) return;  // double-clicked something that isn't a word, e.g. code
        _entry = nil;
        [_popup setText:WPNotFound(selected) status:nil action:nil];
        [self showPopupNear:anchor pid:pid];
        return;
    }
    NSMutableOrderedSet<NSString *> *forms = [NSMutableOrderedSet orderedSetWithObjects:selected.lowercaseString,
                                                                                        entry.headword.lowercaseString, nil];
    WPWord *word = [_vocabulary wordForForms:forms.array];
    _wasListed = word != nil;
    if (word) {
        word.count++;
        [_vocabulary save];
    } else {
        NSDateFormatter *formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd";
        word = [WPWord new];
        word.word = entry.headword.lowercaseString;
        word.meaning = WPShortMeaning(entry);
        word.date = [formatter stringFromDate:[NSDate date]];
        word.count = 1;
        [_vocabulary addWord:word];
    }
    _entry = entry;
    _word = word;
    _forms = forms.array;
    _listed = YES;
    [self renderPopup];
    [self showPopupNear:anchor pid:pid];
}

- (void)renderPopup {
    BOOL red = _listed && _wasListed;
    NSString *status = !_listed ? @"已移出生词本"
                     : _wasListed ? [NSString stringWithFormat:@"第 %ld 次查 · 在生词本里", (long)_word.count]
                                  : @"已加入生词本";
    [_popup setText:WPAttributedEntry(_entry, red) status:status action:_listed ? @"移出生词本" : @"加回生词本"];
}

- (void)toggleListed {
    if (!_entry) return;
    if (_listed) [_vocabulary removeForms:_forms];
    else [_vocabulary addWord:_word];
    _listed = !_listed;
    [self renderPopup];
}

- (void)showPopupNear:(NSRect)anchor pid:(pid_t)pid {
    _popupPid = pid;
    [_popup showNear:anchor];
    if (!_dismissMonitor) {
        __weak WPController *weakSelf = self;
        NSEventMask mask = NSEventMaskKeyDown | NSEventMaskScrollWheel | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown;
        _dismissMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:mask handler:^(NSEvent *event) {
            [weakSelf hidePopup];
        }];
    }
}

- (void)hidePopup {
    if (_dismissMonitor) {
        [NSEvent removeMonitor:_dismissMonitor];
        _dismissMonitor = nil;
    }
    if (_popup.visible) [_popup orderOut:nil];
}

- (void)appActivated:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier != _popupPid && app.processIdentifier != getpid()) [self hidePopup];
}

// Reads the word aloud in the best US English voice installed.
- (void)speak {
    NSString *word = _entry.headword;
    if (!word.length) return;
    if (!_speech) _speech = [AVSpeechSynthesizer new];
    AVSpeechSynthesisVoice *voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    for (AVSpeechSynthesisVoice *candidate in AVSpeechSynthesisVoice.speechVoices) {
        if ([candidate.language isEqualToString:@"en-US"] && candidate.quality > voice.quality) voice = candidate;
    }
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:word];
    utterance.voice = voice;
    [_speech stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [_speech speakUtterance:utterance];
}

#pragma mark Testing

// Renders the popup for a word to a PNG, as a lookup would (it updates the list).
- (BOOL)snapshotWord:(NSString *)word to:(NSString *)path toggle:(BOOL)toggle {
    NSString *clean = WPCleanWord(word, YES);
    [self lookUp:clean ?: word anchor:NSMakeRect(400, 400, 40, 20) pid:0 explicit:YES];
    if (toggle) [self toggleListed];
    [_popup orderOut:nil];
    NSImage *image = [_popup snapshot];
    NSBitmapImageRep *rep = (NSBitmapImageRep *)image.representations.firstObject;
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        signal(SIGPIPE, SIG_IGN);  // writing to an OCR helper that just quit must not kill us
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        if (args.count >= 6 && [args[1] isEqualToString:@"--ocr-test"]) {  // x y dump.png result.txt
            // Run through `open -n … --args`, so the capture counts as ours for Screen Recording.
            WPOCRClient *ocr = [WPOCRClient new];
            NSMutableString *out = [NSMutableString string];
            for (int i = 0; i < 2; i++) {  // cold, then warm
                CGRect box = CGRectNull;
                NSString *failure = nil;
                CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
                NSString *word = [ocr wordAt:CGPointMake(args[2].doubleValue, args[3].doubleValue) box:&box
                                      dumpTo:i == 0 ? args[4] : nil failure:&failure];
                [out appendFormat:@"%@\t%@\t%.0f ms\n", word ?: failure, NSStringFromRect(NSRectFromCGRect(box)),
                                  (CFAbsoluteTimeGetCurrent() - start) * 1000];
            }
            [out writeToFile:args[5] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        if (args.count >= 3 && [args[1] isEqualToString:@"--login-item"]) {  // on | off
            SMAppService *service = SMAppService.mainAppService;
            NSError *error = nil;
            if ([args[2] isEqualToString:@"on"]) [service registerAndReturnError:&error];
            else [service unregisterAndReturnError:&error];
            printf("login item status: %ld%s\n", (long)service.status, error ? error.description.UTF8String : "");
            return error ? 1 : 0;
        }
        if (args.count >= 4 && [args[1] isEqualToString:@"--snapshot"]) {
            WPController *controller = [WPController new];
            BOOL toggle = args.count >= 5 && [args[4] isEqualToString:@"toggle"];
            return [controller snapshotWord:args[2] to:args[3] toggle:toggle] ? 0 : 1;
        }
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        WPController *controller = [WPController new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
