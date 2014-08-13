#include <Foundation/Foundation.h>
#include <CoreText/CoreText.h>
#include <node.h>
#include <v8.h>
#include "FontDescriptor.h"
#include "FontManagerResult.h"

Local<Object> createResult(NSString *path, NSString *postscriptName) {
  return createResult([path UTF8String], [postscriptName UTF8String]);
}

Handle<Value> getAvailableFonts(const Arguments& args) {
  HandleScope scope;
    
  NSArray *urls = (NSArray *) CTFontManagerCopyAvailableFontURLs();
  Local<Array> res = Array::New([urls count]);
  
  int i = 0;
  for (NSURL *url in urls) {
    NSString *path = [url path];
    NSString *psName = [[url fragment] stringByReplacingOccurrencesOfString:@"postscript-name=" withString:@""];
    res->Set(i++, createResult(path, psName));
  }
  
  [urls release];
  return scope.Close(res);
}

// converts a Core Text weight (-1 to +1) to a standard weight (100 to 900)
static int convertWeight(float unit) {
  if (unit < 0) {
    return 100 + (1 + unit) * 300;
  } else {
    return 400 + unit * 500;
  }
}

// converts a Core Text width (-1 to +1) to a standard width (1 to 9)
static int convertWidth(float unit) {
  if (unit < 0) {
    return 1 + (1 + unit) * 4;
  } else {
    return 5 + unit * 4;
  }
}

// helper to square a value
static inline int sqr(int value) {
  return value * value;
}

CTFontDescriptorRef getFontDescriptor(FontDescriptor *desc) {
  // build a dictionary of font attributes
  NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
  CTFontSymbolicTraits symbolicTraits = 0;

  if (desc->postscriptName) {
    NSString *postscriptName = [NSString stringWithUTF8String:desc->postscriptName];
    attrs[(id)kCTFontNameAttribute] = postscriptName;
  }

  if (desc->family) {
    NSString *family = [NSString stringWithUTF8String:desc->family];
    attrs[(id)kCTFontFamilyNameAttribute] = family;
  }

  if (desc->style) {
    NSString *style = [NSString stringWithUTF8String:desc->style];
    attrs[(id)kCTFontStyleNameAttribute] = style;
  }

  // build symbolic traits
  if (desc->italic)
    symbolicTraits |= kCTFontItalicTrait;

  if (desc->weight == FontWeightBold)
    symbolicTraits |= kCTFontBoldTrait;

  if (desc->monospace)
    symbolicTraits |= kCTFontMonoSpaceTrait;

  if (desc->width == FontWidthCondensed)
    symbolicTraits |= kCTFontCondensedTrait;

  if (desc->width == FontWidthExpanded)
    symbolicTraits |= kCTFontExpandedTrait;

  if (symbolicTraits) {
    NSDictionary *traits = @{(id)kCTFontSymbolicTrait:[NSNumber numberWithUnsignedInt:symbolicTraits]};
    attrs[(id)kCTFontTraitsAttribute] = traits;
  }

  // create a font descriptor and search for matches
  CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((CFDictionaryRef) attrs);
  [attrs release];
  
  return descriptor;
}

Handle<Value> findFonts(FontDescriptor *desc) {
  CTFontDescriptorRef descriptor = getFontDescriptor(desc);
  NSArray *matches = (NSArray *) CTFontDescriptorCreateMatchingFontDescriptors(descriptor, NULL);
  Local<Array> res = Array::New([matches count]);
  int count = 0;
  
  for (id m in matches) {
    CTFontDescriptorRef match = (CTFontDescriptorRef) m;
    NSURL *url = (NSURL *) CTFontDescriptorCopyAttribute(match, kCTFontURLAttribute);
    NSString *ps = (NSString *) CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute);
    res->Set(count++, createResult([url path], ps));
    [url release];
    [ps release];
  }
  
  [matches release];
  return res;
}

Handle<Value> findFont(FontDescriptor *desc) {  
  CTFontDescriptorRef descriptor = getFontDescriptor(desc);
  NSArray *matches = (NSArray *) CTFontDescriptorCreateMatchingFontDescriptors(descriptor, NULL);
  
  // find the closest match for width and weight attributes
  CTFontDescriptorRef best = NULL;
  int bestMetric = INT_MAX;
  
  for (id m in matches) {
    CTFontDescriptorRef match = (CTFontDescriptorRef) m;
    NSDictionary *dict = (NSDictionary *)CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute);
    
    int weight = convertWeight([dict[(id)kCTFontWeightTrait] floatValue]);
    int width = convertWidth([dict[(id)kCTFontWidthTrait] floatValue]);
    bool italic = ([dict[(id)kCTFontSymbolicTrait] unsignedIntValue] & kCTFontItalicTrait);
        
    // normalize everything to base-900
    int metric = sqr(weight - desc->weight) + 
                 sqr((width - desc->width) * 100) + 
                 sqr((italic != desc->italic) * 900);
    
    if (metric < bestMetric) {
      bestMetric = metric;
      best = match;
    }
    
    [dict release];
    
    // break if this is an exact match
    if (metric == 0)
      break;
  }
      
  // if we found a match, generate and return a URL for it
  if (best) {    
    NSURL *url = (NSURL *) CTFontDescriptorCopyAttribute(best, kCTFontURLAttribute);
    NSString *ps = (NSString *) CTFontDescriptorCopyAttribute(best, kCTFontNameAttribute);
    Local<Object> res = createResult([url path], ps);

    [url release];
    [ps release];
    [matches release];
    
    return res;
  }
  
  CFRelease(descriptor);
  return Null();
}

Handle<Value> substituteFont(char *postscriptName, char *string) {
  // create a font descriptor to find the font by its postscript name
  // we don't use CTFontCreateWithName because that will return a best
  // match even if the font doesn't actually exist.
  NSString *ps = [NSString stringWithUTF8String:postscriptName];
  NSDictionary *attrs = @{(id)kCTFontNameAttribute: ps};
  CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((CFDictionaryRef) attrs);
  [attrs release];
  
  // find a match
  CTFontDescriptorRef match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, NULL);
  CFRelease(descriptor);
  
  if (match) {
    // copy the font descriptor for this match and create a substitute font matching the given string
    CTFontRef font = CTFontCreateWithFontDescriptor(match, 12.0, NULL);
    NSString *str = [NSString stringWithUTF8String:string];
    CTFontRef substituteFont = CTFontCreateForString(font, (CFStringRef) str, CFRangeMake(0, [str length]));
    CTFontDescriptorRef substituteDescriptor = CTFontCopyFontDescriptor(substituteFont);
    
    // finally, create and return a result object for this substitute font
    NSURL *url = (NSURL *) CTFontDescriptorCopyAttribute(substituteDescriptor, kCTFontURLAttribute);
    NSString *ps = (NSString *) CTFontDescriptorCopyAttribute(substituteDescriptor, kCTFontNameAttribute);
    Local<Object> res = createResult([url path], ps);
    
    CFRelease(font);
    [str release];
    CFRelease(substituteFont);
    CFRelease(substituteDescriptor);
    [url release];
    [ps release];
    
    return res;
  }
  
  return Null();
}
