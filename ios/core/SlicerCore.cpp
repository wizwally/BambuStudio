// SlicerCore implementation. Uses only libslic3r (no wxWidgets, no OpenGL).
//
// Sequence mirrors the single-plate path of src/BambuStudio.cpp (CLI), minus the
// GUI::PartPlateList logic: presets are resolved by PresetBundle::full_config(),
// the model is centred on the bed, then Print::apply/process/export_gcode.

#include "SlicerCore.hpp"

#include "libslic3r/libslic3r.h"
#include "libslic3r/Model.hpp"
#include "libslic3r/Preset.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/Utils.hpp"
#include "libslic3r/GCode/GCodeProcessor.hpp"

#include <boost/filesystem.hpp>
#include <tbb/task_arena.h>

#include <chrono>
#include <memory>
#include <sys/resource.h>

namespace SlicerCore {

using namespace Slic3r;
namespace fs = boost::filesystem;

namespace {

double seconds_since(std::chrono::steady_clock::time_point t0)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

std::size_t peak_rss_bytes()
{
    struct rusage usage {};
    getrusage(RUSAGE_SELF, &usage);
#if defined(__APPLE__)
    return static_cast<std::size_t>(usage.ru_maxrss);          // bytes on Darwin
#else
    return static_cast<std::size_t>(usage.ru_maxrss) * 1024u;  // kilobytes on Linux
#endif
}

void setup_dirs(const std::string& resources_dir, const std::string& data_dir)
{
    set_resources_dir(resources_dir);
    set_data_dir(data_dir);
    fs::path tmp = fs::path(data_dir) / "tmp";
    fs::create_directories(tmp);
    set_temporary_dir(tmp.string());
}

// Loads one vendor bundle straight from resources/profiles (no copy into data_dir,
// no user presets, no AppConfig): enough for the PoC.
void load_vendor(PresetBundle& bundle, const std::string& resources_dir, const std::string& vendor)
{
    const std::string profiles = (fs::path(resources_dir) / "profiles").string();
    bundle.load_vendor_configs_from_json(profiles, vendor, PresetBundle::LoadSystem,
                                         ForwardCompatibilitySubstitutionRule::EnableSilent);
}

bool lists_printer(const Preset& preset, const std::string& printer)
{
    if (printer.empty())
        return true;
    auto* opt = preset.config.option<ConfigOptionStrings>("compatible_printers");
    if (opt == nullptr || opt->values.empty())
        return true; // no restriction declared
    return std::find(opt->values.begin(), opt->values.end(), printer) != opt->values.end();
}

} // namespace

PresetNames list_presets(const std::string& resources_dir, const std::string& data_dir,
                         const std::string& vendor, const std::string& printer_filter)
{
    setup_dirs(resources_dir, data_dir);
    PresetBundle bundle;
    load_vendor(bundle, resources_dir, vendor);

    PresetNames out;
    for (const Preset& p : bundle.printers)
        if (p.is_system && p.is_visible)
            out.printers.push_back(p.name);
    for (const Preset& p : bundle.prints)
        if (p.is_system && p.is_visible && lists_printer(p, printer_filter))
            out.processes.push_back(p.name);
    for (const Preset& p : bundle.filaments)
        if (p.is_system && p.is_visible && lists_printer(p, printer_filter))
            out.filaments.push_back(p.name);
    return out;
}

namespace {

Result slice_impl(const Request& req, const ProgressFn& progress)
{
    Result res;
    auto report = [&](int pct, const std::string& msg) { if (progress) progress(pct, msg); };

    try {
        auto t0 = std::chrono::steady_clock::now();
        setup_dirs(req.resources_dir, req.data_dir);

        // 1. Presets -> full config
        report(0, "Loading presets");
        PresetBundle bundle;
        load_vendor(bundle, req.resources_dir, req.vendor);

        if (!bundle.printers.select_preset_by_name(req.printer, true))
            throw std::runtime_error("printer preset not found: " + req.printer);
        if (!bundle.prints.select_preset_by_name(req.process, true))
            throw std::runtime_error("process preset not found: " + req.process);
        if (req.filaments.empty())
            throw std::runtime_error("at least one filament preset is required");
        for (const std::string& f : req.filaments)
            if (bundle.filaments.find_preset(f, false) == nullptr)
                throw std::runtime_error("filament preset not found: " + f);
        bundle.filament_presets = req.filaments;
        bundle.filaments.select_preset_by_name(req.filaments.front(), true);

        DynamicPrintConfig config = bundle.full_config();

        // 2. Model
        report(5, "Loading model");
        Model model = Model::read_from_file(req.model_path, nullptr, nullptr,
                                            LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
        if (model.objects.empty())
            throw std::runtime_error("model has no objects: " + req.model_path);
        model.add_default_instances();

        // Centre on the printable area (single plate, no arrange yet).
        BoundingBoxf bed_bb;
        for (const Vec2d& p : config.option<ConfigOptionPoints>("printable_area")->values)
            bed_bb.merge(p);
        for (ModelObject* obj : model.objects)
            obj->ensure_on_bed();
        model.center_instances_around_point(bed_bb.center());
        res.load_seconds = seconds_since(t0);

        // 3. Apply + validate
        report(10, "Applying configuration");
        Print print;
        const std::string printer_model = config.opt_string("printer_model");
        print.set_BBL_Printer(printer_model.rfind("Bambu Lab", 0) == 0);
        print.set_status_callback([&](const PrintBase::SlicingStatus& s) {
            if (s.percent >= 0)
                report(10 + s.percent * 80 / 100, s.text);
        });
        print.apply(model, config);

        StringObjectException warning;
        StringObjectException err = print.validate(&warning);
        if (!err.string.empty())
            throw std::runtime_error("validation failed: " + err.string);
        res.warning = warning.string;
        if (print.empty())
            throw std::runtime_error("nothing to slice: object outside the printable area?");

        // 4. Slice
        auto t1 = std::chrono::steady_clock::now();
        print.process();
        res.slice_seconds = seconds_since(t1);

        // 5. Export G-code
        report(90, "Exporting G-code");
        auto t2 = std::chrono::steady_clock::now();
        GCodeProcessorResult gcode_result;
        res.gcode_path = print.export_gcode(req.output_gcode, &gcode_result, nullptr);
        res.export_seconds = seconds_since(t2);

        const auto& mode = gcode_result.print_statistics.modes[static_cast<size_t>(PrintEstimatedStatistics::ETimeMode::Normal)];
        res.estimated_print_seconds = mode.time;
        res.layer_count = mode.layers_times.size();
        res.ok = true;
        report(100, "Done");
    } catch (const std::exception& e) {
        res.ok = false;
        res.error = e.what();
    }

    res.peak_rss_bytes = peak_rss_bytes();
    return res;
}

} // namespace

Result slice(const Request& req, const ProgressFn& progress)
{
    if (req.max_threads <= 0)
        return slice_impl(req, progress);

    // Limit parallelism with a dedicated arena, NOT tbb::global_control.
    // libslic3r's name_tbb_thread_pool_threads_set_locale() (called from
    // Print::process) runs a barrier sized on this_task_arena::max_concurrency():
    // with global_control capping the workers below that value, the barrier never
    // completes and slicing deadlocks (seen on macOS with 10 cores and 3 threads).
    // Inside an arena, max_concurrency() equals the limit and the barrier is met.
    tbb::task_arena arena(req.max_threads);
    Result res;
    arena.execute([&] { res = slice_impl(req, progress); });
    return res;
}

} // namespace SlicerCore
