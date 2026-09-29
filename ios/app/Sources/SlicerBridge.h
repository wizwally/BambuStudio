// Objective-C facade over SlicerCore (C++), callable from Swift.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Extrusion paths for the layer preview (see SlicerCore::Toolpaths).
@interface SCToolpaths : NSObject
/// 9 floats per segment: x0 y0 z0 x1 y1 z1 width height role (mm, bed coordinates).
@property (nonatomic, strong) NSData *segments;
/// UInt32 per layer + 1: layer i spans segments [layerFirst[i], layerFirst[i+1]).
@property (nonatomic, strong) NSData *layerFirst;
/// Float per layer: top z of the layer.
@property (nonatomic, strong) NSData *layerZ;
@property (nonatomic) NSUInteger segmentCount;
@property (nonatomic) NSUInteger layerCount;
@end

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
@property (nonatomic, strong, nullable) SCToolpaths *toolpaths;
@end

/// Model triangles as placed on the bed, plus the bed (see SlicerCore::Mesh).
@interface SCMesh : NSObject
@property (nonatomic) BOOL ok;
@property (nonatomic, copy) NSString *error;
/// 6 floats per vertex (x y z nx ny nz), 3 vertices per triangle.
@property (nonatomic, strong) NSData *vertices;
@property (nonatomic) NSUInteger triangleCount;
@property (nonatomic) float minX, minY, minZ, maxX, maxY, maxZ;
/// Printable area polygon: 2 floats (x y) per point.
@property (nonatomic, strong) NSData *bedOutline;
@property (nonatomic) float bedHeight;
@property (nonatomic) double loadSeconds;
@end

/// System presets of the vendor bundle (see SlicerCore::list_presets).
@interface SCPresetList : NSObject
@property (nonatomic, copy) NSArray<NSString *> *printers;
/// printer_model of each printer ("Bambu Lab P1S"), same order as printers.
@property (nonatomic, copy) NSArray<NSString *> *printerModels;
/// Processes and filaments compatible with the requested printer.
@property (nonatomic, copy) NSArray<NSString *> *processes;
@property (nonatomic, copy) NSArray<NSString *> *filaments;
/// The printer's default process / filament ("" when unknown).
@property (nonatomic, copy) NSString *defaultProcess;
@property (nonatomic, copy) NSString *defaultFilament;
@property (nonatomic) double loadSeconds;
@end

typedef void (^SCProgressBlock)(NSInteger percent, NSString *message);

@interface SCSlicer : NSObject

/// Slices one model with Bambu system presets. Blocking: call it off the main thread.
/// With collectToolpaths the result carries the extrusion paths for the preview.
+ (SCSliceResult *)sliceModelAtPath:(NSString *)modelPath
                            printer:(NSString *)printer
                            process:(NSString *)process
                           filament:(NSString *)filament
                         outputPath:(NSString *)outputPath
                         maxThreads:(NSInteger)maxThreads
                   collectToolpaths:(BOOL)collectToolpaths
                           progress:(nullable SCProgressBlock)progress;

/// Loads the model placed on the bed exactly as sliceModelAtPath does. Blocking.
+ (SCMesh *)loadMeshAtPath:(NSString *)modelPath
                   printer:(NSString *)printer
                   process:(NSString *)process
                  filament:(NSString *)filament
                maxThreads:(NSInteger)maxThreads;

/// Lists the Bambu system presets; with a printer, only the compatible processes and filaments.
/// Blocking (parses all vendor profiles, about a second): call it off the main thread.
+ (SCPresetList *)presetsForPrinter:(nullable NSString *)printer;

/// Name of a toolpath role value ("Outer wall", "Sparse infill", ...).
+ (NSString *)roleName:(NSInteger)role;

/// Folder inside the app bundle (BambuResources/) that holds profiles/BBL.json and profiles/BBL/.
/// Not "resources": a top-level Resources/ folder makes CFBundle treat the app as an
/// old-style bundle and look for Resources/Info.plist ("Missing bundle ID" on install).
+ (NSString *)resourcesPath;

@end

NS_ASSUME_NONNULL_END
