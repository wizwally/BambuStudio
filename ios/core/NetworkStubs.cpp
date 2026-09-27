// Stubs for GUI-layer symbols that libslic3r reaches through LogSink.cpp.
//
// libslic3r/LogSink.cpp (encrypted log files) calls Slic3r::Http, which lives in
// src/slic3r/Utils/Http.cpp and depends on libcurl, and BBL_Encrypt from
// src/slic3r/Utils/BBLUtil.cpp. In the GUI-free core we do not fetch log
// encryption keys from the network and we do not encrypt logs: these stubs make
// every such call a no-op that reports failure, so LogSink falls back to its
// defaults. Nothing else in the slicing path uses these classes.

#include "slic3r/Utils/Http.hpp"
#include "slic3r/Utils/BBLUtil.hpp"

namespace Slic3r {

struct Http::priv {};

Http::Http(const std::string& /*url*/) : p(nullptr) {}
Http::Http(Http&& other) : p(std::move(other.p)) {}
Http::~Http() = default;

Http Http::get(std::string url) { return Http{url}; }
Http& Http::timeout_max(long /*timeout*/) { return *this; }
Http& Http::on_complete(CompleteFn /*fn*/) { return *this; }
Http& Http::on_error(ErrorFn /*fn*/) { return *this; }
void Http::perform_sync() {}

bool BBL_Encrypt::AES256CBC_Encrypt(unsigned char*, unsigned, unsigned char*, unsigned& out_len,
                                    const std::string&, const std::string&)
{
    out_len = 0;
    return false;
}

bool BBL_Encrypt::AES256CBC_Decrypt(unsigned char*, unsigned, unsigned char*, unsigned& out_len,
                                    const std::string&, const std::string&)
{
    out_len = 0;
    return false;
}

} // namespace Slic3r
