// SlicerCore: minimal, GUI-free slicing facade over libslic3r.
//
// This header deliberately does not include any libslic3r header, so it can be
// used from an Objective-C++ bridge (iPad app) or from the test CLI without
// dragging in Boost/TBB/Eigen.
#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace SlicerCore {

struct Request {
    std::string resources_dir;   // BambuStudio "resources" folder (profiles live in resources/profiles)
    std::string data_dir;        // writable folder for logs/cache (app sandbox on iPad)
    std::string vendor = "BBL";  // vendor bundle to load from resources/profiles

    std::string printer;                 // e.g. "Bambu Lab P1S 0.4 nozzle"
    std::string process;                 // e.g. "0.20mm Standard @BBL X1C"
    std::vector<std::string> filaments;  // e.g. {"Bambu PLA Basic @BBL P1S 0.4 nozzle"}

    std::string model_path;   // .stl / .3mf / .obj
    std::string output_gcode; // destination .gcode

    int max_threads = 0;      // 0 = let TBB decide; on iPad set it explicitly

    bool collect_toolpaths = false; // fill Result::toolpaths for the layer preview
};

// Extrusion paths of the sliced print, for the 3D layer preview. Taken from the
// GCodeProcessor result (the same data the desktop preview draws), in print order.
struct Toolpaths {
    // 9 floats per segment: x0 y0 z0 x1 y1 z1 width height role
    // (mm, bed coordinates; z is the top of the extrusion; role is the
    // libslic3r ExtrusionRole value, see role_name()).
    std::vector<float> segments;
    // Layer i spans segments [layer_first[i], layer_first[i + 1]); size = layers + 1.
    std::vector<std::uint32_t> layer_first;
    std::vector<float> layer_z;             // top z of each layer
    std::size_t segment_count() const { return segments.size() / 9; }
    std::size_t layer_count() const { return layer_z.size(); }
};
static constexpr int kToolpathFloats = 9;

struct Result {
    bool ok = false;
    std::string error;
    std::string warning;
    double load_seconds = 0;
    double slice_seconds = 0;
    double export_seconds = 0;
    std::size_t peak_rss_bytes = 0;
    std::size_t layer_count = 0;
    double estimated_print_seconds = 0;
    std::string gcode_path;
    Toolpaths toolpaths;      // filled when Request::collect_toolpaths is set
};

using ProgressFn = std::function<void(int percent, const std::string& message)>;

// Runs load -> apply -> process -> export_gcode for a single plate.
Result slice(const Request& req, const ProgressFn& progress = nullptr);

// Triangles of the model as placed on the bed by slice() (same presets, same
// centring), plus the bed, for the 3D view before slicing.
struct Mesh {
    bool ok = false;
    std::string error;
    // 6 floats per vertex (x y z nx ny nz), 3 vertices per triangle, flat normals.
    std::vector<float> vertices;
    std::size_t triangle_count = 0;
    float min[3] = {0, 0, 0}, max[3] = {0, 0, 0}; // model bounding box
    std::vector<float> bed_outline;               // printable area polygon, x y pairs
    float bed_height = 0;                         // printable height
};

// Loads presets and model like slice() does, without slicing.
// Uses resources_dir, data_dir, vendor, printer, process, filaments, model_path.
Mesh load_mesh(const Request& req);

// Human-readable name of a Toolpaths role value ("Outer wall", "Sparse infill", ...).
std::string role_name(int role);

// Lists printer / process / filament preset names loaded from the vendor bundle.
struct PresetNames {
    std::vector<std::string> printers, processes, filaments;
};
PresetNames list_presets(const std::string& resources_dir, const std::string& data_dir,
                         const std::string& vendor = "BBL", const std::string& printer_filter = "");

} // namespace SlicerCore
