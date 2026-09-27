# GUI-free slicing core for the iPad port.
# Included from src/CMakeLists.txt when SLIC3R_CORE_ONLY=ON, after libslic3r.

# Symbols that libslic3r needs but that upstream only builds in the GUI layer.
# Kept as an OBJECT library and handed to every consumer as object files, so the
# linker sees them regardless of static-archive order.
add_library(slicer_core_gui_shims OBJECT
    NetworkStubs.cpp   # Http / BBL_Encrypt used by libslic3r/LogSink.cpp
    NanoSVG.cpp        # nsvgParse* used by libslic3r, implemented only in the GUI
)
target_link_libraries(slicer_core_gui_shims PRIVATE libslic3r)

add_library(slicer_core STATIC
    SlicerCore.cpp
    SlicerCore.hpp
)
target_sources(slicer_core INTERFACE $<TARGET_OBJECTS:slicer_core_gui_shims>)
target_include_directories(slicer_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(slicer_core PUBLIC libslic3r)
# libslic3r uses OpenSSL (MD5 in 3MF, AES in LogSink) without linking it itself.
target_link_libraries(slicer_core PUBLIC OpenSSL::Crypto)
if (TARGET cereal)
    target_link_libraries(slicer_core PUBLIC cereal)
endif ()

if (APPLE)
    target_link_libraries(slicer_core PUBLIC "-liconv" "-framework CoreFoundation" "-framework Foundation" "-framework ModelIO")
endif ()

# Desktop test driver (not built for iOS).
if (NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
    add_executable(bbs-core-slice main.cpp)
    target_link_libraries(bbs-core-slice PRIVATE slicer_core)
endif ()
