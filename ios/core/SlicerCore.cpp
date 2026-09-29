// SlicerCore implementation. Uses only libslic3r (no wxWidgets, no OpenGL).
//
// Sequence mirrors the single-plate path of src/BambuStudio.cpp (CLI), minus the
// GUI::PartPlateList logic: presets are resolved by PresetBundle::full_config(),
// the model is centred on the bed, then Print::apply/process/export_gcode.

#include "SlicerCore.hpp"

#include "libslic3r/libslic3r.h"
#include "libslic3r/ExtrusionEntity.hpp"
#include "libslic3r/TriangleMesh.hpp"
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

// Presets -> full config. The same selection is used by slice() and load_mesh().
DynamicPrintConfig load_config(const Request& req)
{
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

    return bundle.full_config();
}

BoundingBoxf bed_bounding_box(const DynamicPrintConfig& config)
{
    BoundingBoxf bed_bb;
    for (const Vec2d& p : config.option<ConfigOptionPoints>("printable_area")->values)
        bed_bb.merge(p);
    return bed_bb;
}

// Loads the model and centres it on the printable area (single plate, no arrange yet).
Model load_model(const Request& req, const DynamicPrintConfig& config)
{
    Model model = Model::read_from_file(req.model_path, nullptr, nullptr,
                                        LoadStrategy::LoadModel | LoadStrategy::AddDefaultInstances);
    if (model.objects.empty())
        throw std::runtime_error("model has no objects: " + req.model_path);
    model.add_default_instances();
    for (ModelObject* obj : model.objects)
        obj->ensure_on_bed();
    model.center_instances_around_point(bed_bounding_box(config).center());
    return model;
}

// Extrusion moves of the processed G-code -> Toolpaths (see SlicerCore.hpp).
void collect_toolpaths(const GCodeProcessorResult& gcode, Toolpaths& tp)
{
    tp = Toolpaths{};
    const auto& moves = gcode.moves;
    tp.segments.reserve(moves.size() * kToolpathFloats / 2);

    auto push = [&](const Vec3f& a, const Vec3f& b, const GCodeProcessorResult::MoveVertex& m) {
        tp.segments.insert(tp.segments.end(), {a.x(), a.y(), a.z(), b.x(), b.y(), b.z(),
                                               m.width, m.height, float(m.extrusion_role)});
    };

    float layer_top = -1.f;
    for (std::size_t i = 1; i < moves.size(); ++i) {
        const auto& m = moves[i];
        if (m.type != EMoveType::Extrude || m.width <= 0.f || m.height <= 0.f)
            continue;
        // Start G-code (prime line, nozzle wipe) is erCustom: not part of the object.
        if (m.extrusion_role == erCustom || m.extrusion_role == erNone)
            continue;

        const float z = m.position.z();
        if (tp.layer_z.empty() || z > layer_top + 0.01f) {
            tp.layer_first.push_back(std::uint32_t(tp.segment_count()));
            tp.layer_z.push_back(z);
            layer_top = z;
        }

        Vec3f prev = moves[i - 1].position;
        if (m.is_arc_move_with_interpolation_points())
            for (const Vec3f& p : m.interpolation_points) {
                push(prev, p, m);
                prev = p;
            }
        push(prev, m.position, m);
    }
    tp.layer_first.push_back(std::uint32_t(tp.segment_count()));
}

Result slice_impl(const Request& req, const ProgressFn& progress)
{
    Result res;
    auto report = [&](int pct, const std::string& msg) { if (progress) progress(pct, msg); };

    try {
        auto t0 = std::chrono::steady_clock::now();
        setup_dirs(req.resources_dir, req.data_dir);

        // 1. Presets -> full config
        report(0, "Loading presets");
        DynamicPrintConfig config = load_config(req);

        // 2. Model
        report(5, "Loading model");
        Model model = load_model(req, config);
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
        if (req.collect_toolpaths)
            collect_toolpaths(gcode_result, res.toolpaths);
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

Mesh load_mesh_impl(const Request& req)
{
    Mesh out;
    try {
        setup_dirs(req.resources_dir, req.data_dir);
        DynamicPrintConfig config = load_config(req);
        Model model = load_model(req, config);

        const TriangleMesh mesh = model.mesh();
        const indexed_triangle_set& its = mesh.its;
        out.triangle_count = its.indices.size();
        out.vertices.reserve(its.indices.size() * 18);
        for (const stl_triangle_vertex_indices& f : its.indices) {
            const Vec3f& a = its.vertices[f[0]];
            const Vec3f& b = its.vertices[f[1]];
            const Vec3f& c = its.vertices[f[2]];
            Vec3f n = (b - a).cross(c - a);
            const float len = n.norm();
            n = len > 0.f ? Vec3f(n / len) : Vec3f(0.f, 0.f, 1.f);
            for (const Vec3f* v : {&a, &b, &c})
                out.vertices.insert(out.vertices.end(), {v->x(), v->y(), v->z(), n.x(), n.y(), n.z()});
        }

        const BoundingBoxf3 bb = mesh.bounding_box();
        for (int i = 0; i < 3; ++i) {
            out.min[i] = float(bb.min[i]);
            out.max[i] = float(bb.max[i]);
        }
        for (const Vec2d& p : config.option<ConfigOptionPoints>("printable_area")->values)
            out.bed_outline.insert(out.bed_outline.end(), {float(p.x()), float(p.y())});
        out.bed_height = float(config.opt_float("printable_height"));
        out.ok = true;
    } catch (const std::exception& e) {
        out.ok = false;
        out.error = e.what();
    }
    return out;
}

// Limit parallelism with a dedicated arena, NOT tbb::global_control.
// libslic3r's name_tbb_thread_pool_threads_set_locale() (called from
// Print::process) runs a barrier sized on this_task_arena::max_concurrency():
// with global_control capping the workers below that value, the barrier never
// completes and slicing deadlocks (seen on macOS with 10 cores and 3 threads).
// Inside an arena, max_concurrency() equals the limit and the barrier is met.
template<typename Fn>
auto run_limited(int max_threads, Fn&& fn) -> decltype(fn())
{
    if (max_threads <= 0)
        return fn();
    tbb::task_arena arena(max_threads);
    decltype(fn()) out;
    arena.execute([&] { out = fn(); });
    return out;
}

} // namespace

Result slice(const Request& req, const ProgressFn& progress)
{
    return run_limited(req.max_threads, [&] { return slice_impl(req, progress); });
}

Mesh load_mesh(const Request& req)
{
    return run_limited(req.max_threads, [&] { return load_mesh_impl(req); });
}

std::string role_name(int role)
{
    if (role < 0 || role >= int(erCount))
        return "Unknown";
    return ExtrusionEntity::role_to_string(ExtrusionRole(role));
}

} // namespace SlicerCore
