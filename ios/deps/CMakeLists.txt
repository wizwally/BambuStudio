# iOS (arm64, iPadOS) superbuild of the libslic3r dependencies.
#
# The superbuild itself runs natively on macOS; every dependency is configured
# as an iOS cross build. Where upstream recipes in deps/ work unchanged for iOS
# they are included as-is (same URLs, hashes and patches); GMP, MPFR and OpenSSL
# use autotools/Perl and get iOS-specific recipes below.
#
# Configured by ios/scripts/ios_01_deps.sh.

cmake_minimum_required(VERSION 3.16)
project(BambuStudio-ios-deps NONE)

include(ExternalProject)
include(ProcessorCount)
ProcessorCount(NPROC)
if (NPROC EQUAL 0)
    set(NPROC 1)
endif ()

set(REPO_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." CACHE PATH "BambuStudio repository root")
get_filename_component(REPO_ROOT "${REPO_ROOT}" ABSOLUTE)
set(UPSTREAM_DEPS "${REPO_ROOT}/deps")

set(IOS_DEPLOYMENT_TARGET "17.0" CACHE STRING "Minimum iPadOS version")
set(DESTDIR "${CMAKE_CURRENT_BINARY_DIR}/BambuStudio_deps" CACHE PATH "Install root")
set(DEP_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/download" CACHE PATH "Download cache")
set(PREFIX "${DESTDIR}/usr/local")
file(MAKE_DIRECTORY "${PREFIX}/include" "${PREFIX}/lib")

find_package(Git REQUIRED)
set(PATCH_CMD ${GIT_EXECUTABLE} apply --verbose --ignore-space-change --whitespace=fix)
# Upstream recipes run "git apply --directory <build dir relative to repo root>".
set(IN_GIT_REPO TRUE)
file(RELATIVE_PATH BINARY_DIR_REL "${REPO_ROOT}" "${CMAKE_CURRENT_BINARY_DIR}")

execute_process(COMMAND xcrun --sdk iphoneos --show-sdk-path
                OUTPUT_VARIABLE IOS_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND xcrun --sdk iphoneos --find clang
                OUTPUT_VARIABLE IOS_CC OUTPUT_STRIP_TRAILING_WHITESPACE)
execute_process(COMMAND xcrun --sdk iphoneos --find clang++
                OUTPUT_VARIABLE IOS_CXX OUTPUT_STRIP_TRAILING_WHITESPACE)
if (NOT IOS_SDK OR NOT EXISTS "${IOS_SDK}")
    message(FATAL_ERROR "iPhoneOS SDK not found: is Xcode installed and selected (xcode-select -p)?")
endif ()
message(STATUS "iOS SDK: ${IOS_SDK}  (min iPadOS ${IOS_DEPLOYMENT_TARGET})")

# Values some upstream recipes read. The superbuild is native arm64 macOS, so the
# recipes take their "Apple, not cross compiling" branches.
set(CMAKE_OSX_ARCHITECTURES arm64)
set(DEP_OSX_TARGET ${IOS_DEPLOYMENT_TARGET})
set(IS_CROSS_COMPILE FALSE)
set(CMAKE_BUILD_TYPE Release)

set(IOS_FLAGS "-arch arm64 -isysroot ${IOS_SDK} -mios-version-min=${IOS_DEPLOYMENT_TARGET}")

# Arguments every CMake-based dependency gets. The FIND_ROOT_PATH settings keep
# CMake inside the iOS SDK + our prefix, so nothing leaks in from /opt/homebrew.
set(IOS_CMAKE_ARGS
    -DCMAKE_SYSTEM_NAME=iOS
    -DCMAKE_OSX_SYSROOT=iphoneos
    -DCMAKE_OSX_ARCHITECTURES=arm64
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET}
    -DCMAKE_INSTALL_PREFIX=${PREFIX}
    -DCMAKE_PREFIX_PATH=${PREFIX}
    -DCMAKE_FIND_ROOT_PATH=${PREFIX}
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY
    -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew
    -DCMAKE_MODULE_PATH=${REPO_ROOT}/cmake/modules
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    -DCMAKE_MACOSX_BUNDLE=OFF
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_DEBUG_POSTFIX=d
)

# Per-project extra arguments, appended last so they win over the recipe's own -D.
set(IOS_EXTRA_Boost
    "-DBOOST_EXCLUDE_LIBRARIES=contract|fiber|numpy|wave|test|coroutine|cobalt|stacktrace|python|mpi|graph_parallel|process"
    -DBOOST_IOSTREAMS_ENABLE_ZSTD=OFF
    -DBOOST_IOSTREAMS_ENABLE_LZMA=OFF
    -DBOOST_IOSTREAMS_ENABLE_BZIP2=OFF
    -DBOOST_IOSTREAMS_ENABLE_ZLIB=ON
)
set(IOS_EXTRA_OpenVDB -DOPENVDB_BUILD_VDB_PRINT=OFF -DOPENVDB_BUILD_BINARIES=OFF -DUSE_EXR=OFF)
set(IOS_EXTRA_OpenCV
    -DAPPLE_FRAMEWORK=OFF
    -DBUILD_opencv_objc=OFF
    -DBUILD_TIFF=OFF -DWITH_TIFF=OFF
    -DWITH_AVFOUNDATION=OFF -DWITH_IMGCODEC_HDR=OFF
    -DCV_ENABLE_INTRINSICS=ON
)
set(IOS_EXTRA_OCCT -DUSE_FREETYPE=ON -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF -DUSE_D3D=OFF)
set(IOS_EXTRA_Qhull -DBUILD_APPLICATIONS=OFF)
set(IOS_EXTRA_Blosc -DDEACTIVATE_AVX2=ON -DDEACTIVATE_SSE2=ON)

function(bambustudio_add_cmake_project projectname)
    cmake_parse_arguments(P_ARGS "" "INSTALL_DIR;BUILD_COMMAND;INSTALL_COMMAND" "CMAKE_ARGS" ${ARGN})
    ExternalProject_Add(
        dep_${projectname}
        EXCLUDE_FROM_ALL    ON
        INSTALL_DIR         ${PREFIX}
        DOWNLOAD_DIR        ${DEP_DOWNLOAD_DIR}/${projectname}
        CMAKE_ARGS
            ${IOS_CMAKE_ARGS}
            ${P_ARGS_CMAKE_ARGS}
            ${IOS_EXTRA_${projectname}}
        ${P_ARGS_UNPARSED_ARGUMENTS}
        BUILD_COMMAND   ${CMAKE_COMMAND} --build . --config Release -- -j${NPROC}
        INSTALL_COMMAND ${CMAKE_COMMAND} --build . --target install --config Release
    )
endfunction()

# ---------------------------------------------------------------------------
# zlib, bzip2, iconv and expat-free system libs come from the iOS SDK.
set(ZLIB_PKG "")
set(DEP_BUILD_FREETYPE ON)

include(${UPSTREAM_DEPS}/EXPAT/EXPAT.cmake)
include(${UPSTREAM_DEPS}/PNG/PNG.cmake)
include(${UPSTREAM_DEPS}/Boost/Boost.cmake)
set(BOOST_PKG dep_Boost)
include(${UPSTREAM_DEPS}/Cereal/Cereal.cmake)
include(${UPSTREAM_DEPS}/Qhull/Qhull.cmake)
include(${UPSTREAM_DEPS}/TBB/TBB.cmake)
include(${UPSTREAM_DEPS}/Blosc/Blosc.cmake)
set(BLOSC_PKG dep_Blosc)
include(${UPSTREAM_DEPS}/OpenEXR/OpenEXR.cmake)
include(${UPSTREAM_DEPS}/OpenVDB/OpenVDB.cmake)
include(${UPSTREAM_DEPS}/NLopt/NLopt.cmake)
include(${UPSTREAM_DEPS}/libnoise/libnoise.cmake)
include(${UPSTREAM_DEPS}/FREETYPE/FREETYPE.cmake)
set(FREETYPE_PKG dep_FREETYPE)
include(${UPSTREAM_DEPS}/OCCT/OCCT.cmake)
include(${UPSTREAM_DEPS}/OpenCV/OpenCV.cmake)
include(${UPSTREAM_DEPS}/Assimp/Assimp.cmake)

# ---------------------------------------------------------------------------
# GMP / MPFR (autotools). --host differs from --build so configure treats the
# build as cross compiling and never tries to run iOS binaries on macOS.
set(_ios_autotools_env
    env "CC=${IOS_CC}" "CXX=${IOS_CXX}"
        "CFLAGS=${IOS_FLAGS} -O2 -fPIC -DNDEBUG"
        "CXXFLAGS=${IOS_FLAGS} -O2 -fPIC -DNDEBUG"
        "LDFLAGS=${IOS_FLAGS}")
# --build and --host must differ as strings (both are arm64 Darwin), otherwise
# configure is not in cross mode and tries to run iOS test binaries on macOS.
set(_ios_autotools_triples --build=aarch64-apple-darwin20 --host=aarch64-apple-darwin)

ExternalProject_Add(dep_GMP
    EXCLUDE_FROM_ALL ON
    URL https://github.com/bambulab/gmp/archive/refs/tags/6.2.1.tar.gz
    URL_HASH SHA256=705ae57ee2014b2c6fc0f572c85ee43276b99b6b256ee16c1a9d3a8c4e3609d5
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/GMP
    BUILD_IN_SOURCE ON
    CONFIGURE_COMMAND ${_ios_autotools_env} ./configure ${_ios_autotools_triples}
        --disable-assembly
        --enable-shared=no --enable-static=yes --enable-cxx=yes
        --prefix=${PREFIX}
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
)
set(GMP_PKG dep_GMP)

ExternalProject_Add(dep_MPFR
    EXCLUDE_FROM_ALL ON
    URL http://ftp.vim.org/ftp/gnu/mpfr/mpfr-3.1.6.tar.bz2 https://www.mpfr.org/mpfr-3.1.6/mpfr-3.1.6.tar.bz2
    URL_HASH SHA256=cf4f4b2d80abb79e820e78c8077b6725bbbb4e8f41896783c899087be0e94068
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/MPFR
    BUILD_IN_SOURCE ON
    CONFIGURE_COMMAND ${_ios_autotools_env} ./configure ${_ios_autotools_triples}
        --enable-shared=no --enable-static=yes
        --with-gmp=${PREFIX} --prefix=${PREFIX}
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
    DEPENDS dep_GMP
)
set(MPFR_PKG dep_MPFR)

include(${UPSTREAM_DEPS}/CGAL/CGAL.cmake)
include(${UPSTREAM_DEPS}/OpenMeshCraft/OpenMeshCraft.cmake)

# ---------------------------------------------------------------------------
# OpenSSL: libcrypto only (MD5/AES used by libslic3r), iOS target from OpenSSL.
ExternalProject_Add(dep_OpenSSL
    EXCLUDE_FROM_ALL ON
    URL https://github.com/openssl/openssl/archive/refs/tags/openssl-3.1.2.tar.gz
    URL_HASH SHA256=8c776993154652d0bb393f506d850b811517c8bd8d24b1008aef57fbe55d3f31
    DOWNLOAD_DIR ${DEP_DOWNLOAD_DIR}/OpenSSL
    BUILD_IN_SOURCE ON
    CONFIGURE_COMMAND ./Configure ios64-xcrun
        -mios-version-min=${IOS_DEPLOYMENT_TARGET}
        no-shared no-asm no-tests no-dso no-engine no-ssl3-method no-dynamic-engine
        --prefix=${PREFIX} --openssldir=${PREFIX}
    BUILD_COMMAND make -j${NPROC} build_libs
    INSTALL_COMMAND make install_dev
)

# ---------------------------------------------------------------------------
add_custom_target(deps ALL DEPENDS
    dep_EXPAT dep_PNG dep_Boost dep_Cereal dep_Qhull dep_TBB dep_Blosc dep_OpenEXR
    dep_OpenVDB dep_NLopt dep_libnoise dep_FREETYPE dep_OCCT dep_OpenCV dep_Assimp
    dep_GMP dep_MPFR dep_CGAL dep_OpenMeshCraft dep_OpenSSL)
