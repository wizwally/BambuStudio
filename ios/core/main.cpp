// bbs-core-slice: test driver for SlicerCore (runs on macOS/Linux, not on iPad).
//
//   bbs-core-slice --resources <BambuStudio/resources> --data /tmp/bbs-data \
//       --printer "Bambu Lab P1S 0.4 nozzle" --process "0.20mm Standard @BBL X1C" \
//       --filament "Bambu PLA Basic @BBL P1S 0.4 nozzle" \
//       --threads 3 --out out.gcode model.stl
//
//   bbs-core-slice --resources ... --data ... --list [--printer "..."]

#include "SlicerCore.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string>

static void usage()
{
    std::cerr << "usage: bbs-core-slice --resources DIR --data DIR --printer NAME --process NAME\n"
                 "                      --filament NAME [--filament NAME ...] [--threads N] --out FILE MODEL\n"
                 "       bbs-core-slice --resources DIR --data DIR --list [--printer NAME]\n";
}

int main(int argc, char** argv)
{
    SlicerCore::Request req;
    bool list = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) { usage(); std::exit(2); }
            return argv[++i];
        };
        if (a == "--resources")      req.resources_dir = next();
        else if (a == "--data")      req.data_dir = next();
        else if (a == "--vendor")    req.vendor = next();
        else if (a == "--printer")   req.printer = next();
        else if (a == "--process")   req.process = next();
        else if (a == "--filament")  req.filaments.push_back(next());
        else if (a == "--threads")   req.max_threads = std::atoi(next().c_str());
        else if (a == "--out")       req.output_gcode = next();
        else if (a == "--list")      list = true;
        else if (a == "-h" || a == "--help") { usage(); return 0; }
        else if (!a.empty() && a[0] == '-') { std::cerr << "unknown option " << a << "\n"; usage(); return 2; }
        else req.model_path = a;
    }

    if (req.resources_dir.empty() || req.data_dir.empty()) { usage(); return 2; }

    if (list) {
        auto names = SlicerCore::list_presets(req.resources_dir, req.data_dir, req.vendor, req.printer);
        std::cout << "# printers (" << names.printers.size() << ")\n";
        for (auto& n : names.printers) std::cout << n << "\n";
        std::cout << "# processes (" << names.processes.size() << ")\n";
        for (auto& n : names.processes) std::cout << n << "\n";
        std::cout << "# filaments (" << names.filaments.size() << ")\n";
        for (auto& n : names.filaments) std::cout << n << "\n";
        return 0;
    }

    if (req.printer.empty() || req.process.empty() || req.filaments.empty() ||
        req.model_path.empty() || req.output_gcode.empty()) {
        usage();
        return 2;
    }

    auto r = SlicerCore::slice(req, [](int pct, const std::string& msg) {
        std::fprintf(stderr, "[%3d%%] %s\n", pct, msg.c_str());
    });

    std::printf("ok=%d\n", r.ok ? 1 : 0);
    if (!r.ok) std::printf("error=%s\n", r.error.c_str());
    if (!r.warning.empty()) std::printf("warning=%s\n", r.warning.c_str());
    std::printf("load_s=%.2f slice_s=%.2f export_s=%.2f\n", r.load_seconds, r.slice_seconds, r.export_seconds);
    std::printf("peak_rss_mb=%.0f layers=%zu est_print_min=%.1f\n",
                r.peak_rss_bytes / (1024.0 * 1024.0), r.layer_count, r.estimated_print_seconds / 60.0);
    if (r.ok) std::printf("gcode=%s\n", r.gcode_path.c_str());
    return r.ok ? 0 : 1;
}
