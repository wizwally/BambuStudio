// nanosvg implementation for the GUI-free core.
// libslic3r uses nsvgParse* (SVG emboss/import) but the implementation is only
// compiled in the desktop GUI (src/slic3r/GUI/BitmapCache.cpp).
#include <cstdio>
#include <cstring>
#include <cmath>
#define NANOSVG_IMPLEMENTATION
#include "nanosvg/nanosvg.h"
