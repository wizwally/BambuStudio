# Porting iPad: cartella `ios/`

Obiettivo: usare il motore di slicing di BambuStudio (libslic3r) su iPad Pro M4, senza l'interfaccia desktop (wxWidgets/OpenGL).

## Contenuto

| Percorso | Cosa fa |
| --- | --- |
| `core/SlicerCore.hpp/.cpp` | Facciata senza GUI: carica i preset Bambu, carica il modello, esegue lo slicing, esporta il G-code |
| `core/main.cpp` | `bbs-core-slice`, programma di test da riga di comando (solo macOS/Linux) |
| `core/NetworkStubs.cpp` | Sostituti vuoti di `Http` e `BBL_Encrypt`: libslic3r li usa solo per i log cifrati (chiave scaricata dai server Bambu) |
| `core/NanoSVG.cpp` | Implementazione di nanosvg, che upstream compila solo nella GUI |
| `core/CMakeLists.txt` | Target `slicer_core` e `bbs-core-slice` |
| `tools/flatten_profile.py` | Risolve `inherits`/`include` dei profili in JSON completi (per la CLI ufficiale e per il debug) |
| `tools/compare_gcode.py` | Confronta due G-code: layer, estrusione, movimenti |
| `scripts/mac_01_deps.sh` | Compila le dipendenze per macOS arm64 (senza wxWidgets/FFmpeg/GLFW) |
| `scripts/mac_02_core.sh` | Compila libslic3r + core con `SLIC3R_CORE_ONLY=ON` |
| `scripts/mac_03_test.sh` | Affetta i modelli di test e li confronta con BambuStudio.app |
| `tools/make_test_models.py` | Genera i modelli di test in `test/models/`: `cube20.stl` (semplice), `sphere_dense.stl` (circa 200k triangoli) |

Modifiche fuori da `ios/` (tenute minime per facilitare il rebase con upstream):

- `CMakeLists.txt`: opzione `SLIC3R_CORE_ONLY`; con l'opzione attiva non cerca CURL, OpenGL, GLEW e GLFW.
- `src/CMakeLists.txt`: con `SLIC3R_CORE_ONLY` compila `ios/core` dopo libslic3r e si ferma.
- `src/libslic3r/MeshDiagnostics.hpp`: include mancante (`Point.hpp`), visibile solo compilando senza header precompilati.

## Stato verificato

Compilato ed eseguito su Linux x86_64 (Ubuntu 24.04, librerie di sistema) il 27 settembre 2026, commit upstream `f977235`:

| Modello | Layer | Slicing | Picco RAM | Stima stampa |
| --- | --- | --- | --- | --- |
| `cube20.stl` | 100 | 0,6 s totali | 182 MB | 14 min 51 s |
| `sphere_dense.stl` (circa 200k triangoli) | 400 | circa 8 s totali | 251 MB | 81,7 min |

Profilo: Bambu Lab P1S 0.4 nozzle, 0.20mm Standard @BBL X1C, Bambu PLA Basic @BBL P1S 0.4 nozzle; 2 thread. Il G-code include lo start G-code P1S e l'oggetto centrato sul piatto. Il confronto con BambuStudio ufficiale va ancora fatto sul Mac.

Nota: `libslic3r_version.h` contiene l'ora di build, quindi ogni riconfigurazione CMake ricompila quasi tutto. Dopo la prima volta usa `cmake --build` senza riconfigurare.

## Passi sul Mac

```bash
xcode-select --install          # se non già fatto
brew install cmake ninja        # se mancano
ios/scripts/mac_01_deps.sh      # 30-90 minuti la prima volta
ios/scripts/mac_02_core.sh
ios/scripts/mac_03_test.sh
```

Per il confronto installa BambuStudio ufficiale in `/Applications`. I log finiscono in `ios/logs/`.

## Fasi successive

1. Stessa build per `arm64-apple-ios` (toolchain iOS di CMake, dipendenze statiche in xcframework).
2. App SwiftUI minima che chiama `SlicerCore::slice` tramite un bridge Objective-C++.
3. Estrarre da `src/slic3r/GUI/PartPlate.cpp` la logica dei piatti senza GUI.
