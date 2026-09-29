#import "SlicerBridge.h"

#include "SlicerCore.hpp"

@implementation SCSliceResult
@end

@implementation SCSlicer

+ (NSString *)resourcesPath
{
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"BambuResources"];
}

+ (NSString *)dataPath
{
    NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    NSString *path = [support.path stringByAppendingPathComponent:@"SlicerCore"];
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

+ (SCSliceResult *)sliceModelAtPath:(NSString *)modelPath
                            printer:(NSString *)printer
                            process:(NSString *)process
                           filament:(NSString *)filament
                         outputPath:(NSString *)outputPath
                         maxThreads:(NSInteger)maxThreads
                           progress:(SCProgressBlock)progress
{
    SlicerCore::Request req;
    req.resources_dir = [self resourcesPath].UTF8String;
    req.data_dir      = [self dataPath].UTF8String;
    req.printer       = printer.UTF8String;
    req.process       = process.UTF8String;
    req.filaments     = { filament.UTF8String };
    req.model_path    = modelPath.UTF8String;
    req.output_gcode  = outputPath.UTF8String;
    req.max_threads   = (int)maxThreads;

    SlicerCore::ProgressFn fn = nullptr;
    if (progress) {
        SCProgressBlock block = [progress copy];
        fn = [block](int percent, const std::string &message) {
            block(percent, [NSString stringWithUTF8String:message.c_str()] ?: @"");
        };
    }

    SlicerCore::Result r = SlicerCore::slice(req, fn);

    SCSliceResult *out = [SCSliceResult new];
    out.ok = r.ok;
    out.error = [NSString stringWithUTF8String:r.error.c_str()] ?: @"";
    out.warning = [NSString stringWithUTF8String:r.warning.c_str()] ?: @"";
    out.loadSeconds = r.load_seconds;
    out.sliceSeconds = r.slice_seconds;
    out.exportSeconds = r.export_seconds;
    out.peakRSSBytes = r.peak_rss_bytes;
    out.layerCount = r.layer_count;
    out.estimatedPrintSeconds = r.estimated_print_seconds;
    out.gcodePath = [NSString stringWithUTF8String:r.gcode_path.c_str()] ?: @"";
    return out;
}

@end
