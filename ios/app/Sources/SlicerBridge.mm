#import "SlicerBridge.h"

#include "SlicerCore.hpp"

#include <chrono>
#include <memory>
#include <vector>

@implementation SCToolpaths
@end

@implementation SCSliceResult
@end

@implementation SCMesh
@end

// Hands a std::vector to NSData without copying: the vector is moved to the heap
// and freed when the NSData goes away (toolpaths can be tens of MB).
template<typename T>
static NSData *DataFromVector(std::vector<T> &&v)
{
    if (v.empty())
        return [NSData data];
    auto *owned = new std::vector<T>(std::move(v));
    return [[NSData alloc] initWithBytesNoCopy:owned->data()
                                        length:owned->size() * sizeof(T)
                                   deallocator:^(void *, NSUInteger) { delete owned; }];
}

static NSString *NSStr(const std::string &s)
{
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

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

+ (SlicerCore::Request)requestForModel:(NSString *)modelPath
                               printer:(NSString *)printer
                               process:(NSString *)process
                              filament:(NSString *)filament
                            maxThreads:(NSInteger)maxThreads
{
    SlicerCore::Request req;
    req.resources_dir = [self resourcesPath].UTF8String;
    req.data_dir      = [self dataPath].UTF8String;
    req.printer       = printer.UTF8String;
    req.process       = process.UTF8String;
    req.filaments     = { filament.UTF8String };
    req.model_path    = modelPath.UTF8String;
    req.max_threads   = (int)maxThreads;
    return req;
}

+ (SCSliceResult *)sliceModelAtPath:(NSString *)modelPath
                            printer:(NSString *)printer
                            process:(NSString *)process
                           filament:(NSString *)filament
                         outputPath:(NSString *)outputPath
                         maxThreads:(NSInteger)maxThreads
                   collectToolpaths:(BOOL)collectToolpaths
                           progress:(SCProgressBlock)progress
{
    SlicerCore::Request req = [self requestForModel:modelPath printer:printer process:process
                                           filament:filament maxThreads:maxThreads];
    req.output_gcode      = outputPath.UTF8String;
    req.collect_toolpaths = collectToolpaths;

    SlicerCore::ProgressFn fn = nullptr;
    if (progress) {
        SCProgressBlock block = [progress copy];
        fn = [block](int percent, const std::string &message) { block(percent, NSStr(message)); };
    }

    SlicerCore::Result r = SlicerCore::slice(req, fn);

    SCSliceResult *out = [SCSliceResult new];
    out.ok = r.ok;
    out.error = NSStr(r.error);
    out.warning = NSStr(r.warning);
    out.loadSeconds = r.load_seconds;
    out.sliceSeconds = r.slice_seconds;
    out.exportSeconds = r.export_seconds;
    out.peakRSSBytes = r.peak_rss_bytes;
    out.layerCount = r.layer_count;
    out.estimatedPrintSeconds = r.estimated_print_seconds;
    out.gcodePath = NSStr(r.gcode_path);
    if (r.ok && collectToolpaths) {
        SCToolpaths *tp = [SCToolpaths new];
        tp.segmentCount = r.toolpaths.segment_count();
        tp.layerCount = r.toolpaths.layer_count();
        tp.segments = DataFromVector(std::move(r.toolpaths.segments));
        tp.layerFirst = DataFromVector(std::move(r.toolpaths.layer_first));
        tp.layerZ = DataFromVector(std::move(r.toolpaths.layer_z));
        out.toolpaths = tp;
    }
    return out;
}

+ (SCMesh *)loadMeshAtPath:(NSString *)modelPath
                   printer:(NSString *)printer
                   process:(NSString *)process
                  filament:(NSString *)filament
                maxThreads:(NSInteger)maxThreads
{
    SlicerCore::Request req = [self requestForModel:modelPath printer:printer process:process
                                           filament:filament maxThreads:maxThreads];
    auto t0 = std::chrono::steady_clock::now();
    SlicerCore::Mesh m = SlicerCore::load_mesh(req);

    SCMesh *out = [SCMesh new];
    out.loadSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    out.ok = m.ok;
    out.error = NSStr(m.error);
    out.triangleCount = m.triangle_count;
    out.minX = m.min[0]; out.minY = m.min[1]; out.minZ = m.min[2];
    out.maxX = m.max[0]; out.maxY = m.max[1]; out.maxZ = m.max[2];
    out.bedHeight = m.bed_height;
    out.vertices = DataFromVector(std::move(m.vertices));
    out.bedOutline = DataFromVector(std::move(m.bed_outline));
    return out;
}

+ (NSString *)roleName:(NSInteger)role
{
    return NSStr(SlicerCore::role_name((int)role));
}

@end
