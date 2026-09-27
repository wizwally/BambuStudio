// SlicerCore: minimal, GUI-free slicing facade over libslic3r.
//
// This header deliberately does not include any libslic3r header, so it can be
// used from an Objective-C++ bridge (iPad app) or from the test CLI without
// dragging in Boost/TBB/Eigen.
#pragma once

#include <cstddef>
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
};

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
};

using ProgressFn = std::function<void(int percent, const std::string& message)>;

// Runs load -> apply -> process -> export_gcode for a single plate.
Result slice(const Request& req, const ProgressFn& progress = nullptr);

// Lists printer / process / filament preset names loaded from the vendor bundle.
struct PresetNames {
    std::vector<std::string> printers, processes, filaments;
};
PresetNames list_presets(const std::string& resources_dir, const std::string& data_dir,
                         const std::string& vendor = "BBL", const std::string& printer_filter = "");

} // namespace SlicerCore
