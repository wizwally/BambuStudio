// Objective-C facade over SlicerCore (C++), callable from Swift.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCSliceResult : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic, copy) NSString *error;
@property (nonatomic, copy) NSString *warning;
@property (nonatomic) double loadSeconds;
@property (nonatomic) double sliceSeconds;
@property (nonatomic) double exportSeconds;
@property (nonatomic) NSUInteger peakRSSBytes;
@property (nonatomic) NSUInteger layerCount;
@property (nonatomic) double estimatedPrintSeconds;
@property (nonatomic, copy) NSString *gcodePath;
@end

typedef void (^SCProgressBlock)(NSInteger percent, NSString *message);

@interface SCSlicer : NSObject

/// Slices one model with Bambu system presets. Blocking: call it off the main thread.
+ (SCSliceResult *)sliceModelAtPath:(NSString *)modelPath
                            printer:(NSString *)printer
                            process:(NSString *)process
                           filament:(NSString *)filament
                         outputPath:(NSString *)outputPath
                         maxThreads:(NSInteger)maxThreads
                           progress:(nullable SCProgressBlock)progress;

/// Folder inside the app bundle that holds profiles/BBL.json and profiles/BBL/.
+ (NSString *)resourcesPath;

@end

NS_ASSUME_NONNULL_END
