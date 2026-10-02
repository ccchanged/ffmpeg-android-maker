#!/usr/bin/env bash

# Script to download FFmpeg's source code
# Relies on FFMPEG_SOURCE_TYPE and FFMPEG_SOURCE_VALUE variables
# to choose the valid origin and version

# Exports SOURCES_DIR_ffmpeg - path where actual sources are stored

# Getting sources of a particular FFmpeg release.
# Same argument (FFmpeg version) produces the same source set.
function ensureSourcesTar() {
  source ${SCRIPTS_DIR}/common-functions.sh

  downloadTarArchive \
    "ffmpeg" \
    "https://www.ffmpeg.org/releases/ffmpeg-${FFMPEG_SOURCE_VALUE}.tar.bz2"
}

# Getting sources of a particular branch or a tag of FFmpeg's git repository.
# Same branch name may produce different source set,
# as the branch in origin repository may be updated in future.
# Git tags lead to stable states of the source code.
function ensureSourcesGit() {
  NAME_TO_CHECKOUT=${FFMPEG_SOURCE_VALUE}

  GIT_DIRECTORY=ffmpeg-git

  FFMPEG_SOURCES=$(pwd)/${GIT_DIRECTORY}

  if [[ ! -d "$FFMPEG_SOURCES" ]]; then
    git clone https://git.ffmpeg.org/ffmpeg.git ${GIT_DIRECTORY}
  fi

  cd ${GIT_DIRECTORY}
  git reset --hard

  git checkout $NAME_TO_CHECKOUT
  if [ ${FFMPEG_SOURCE_TYPE} = "GIT_BRANCH" ]; then
    # Forcing the update of a branch
    git pull origin $BRANCH
  fi

  # Additional logging to keep track of an exact commit to build
  echo "Commit to build:"
  git rev-parse HEAD

  export SOURCES_DIR_ffmpeg=${FFMPEG_SOURCES}
}

# Actual code
case ${FFMPEG_SOURCE_TYPE} in
	GIT_TAG)
    echo "Using FFmpeg git tag: ${FFMPEG_SOURCE_VALUE}"
		ensureSourcesGit
		;;
	GIT_BRANCH)
    echo "Using FFmpeg git repository and its branch: ${FFMPEG_SOURCE_VALUE}"
		ensureSourcesGit
		;;
	TAR)
		echo "Using FFmpeg source archive: ${FFMPEG_SOURCE_VALUE}"
    ensureSourcesTar
		;;
esac

# Android/AArch64 PIC fix: FFmpeg's tx_float NEON assembly takes the address
# of FFT tables defined in another object file. A plain movrel uses ADRP/ADD
# relocations that LLD rejects when the static archive is later linked into a
# shared library. Use the GOT-based movrelx sequence for these external tables.
if [ -f "${SOURCES_DIR_ffmpeg}/libavutil/aarch64/asm.S" ] && [ -f "${SOURCES_DIR_ffmpeg}/libavutil/aarch64/tx_float_neon.S" ]; then
  python3 - "${SOURCES_DIR_ffmpeg}" <<'PYTHON' || exit 1
from pathlib import Path
import sys

root = Path(sys.argv[1])
asm = root / "libavutil/aarch64/asm.S"
tx = root / "libavutil/aarch64/tx_float_neon.S"

asm_text = asm.read_text()
if ".macro  movrelx rd, val, offset=0" not in asm_text:
    needle = ".endm\n\n#define GLUE(a, b) a ## b"
    macro = """.endm

/* Load the address of an external symbol through the GOT when building PIC.
 * This avoids text relocations when a static FFmpeg archive is linked into
 * a shared library on Android/AArch64. */
.macro  movrelx rd, val, offset=0
#if CONFIG_PIC
#if defined(__APPLE__)
        adrp            \\rd, \\val at GOTPAGE
        ldr             \\rd, [\\rd, \\val at GOTPAGEOFF]
#else
        adrp            \\rd, :got:\\val
        ldr             \\rd, [\\rd, :got_lo12:\\val]
#endif
    .if \\offset > 0
        add             \\rd, \\rd, \\offset
    .elseif \\offset < 0
        sub             \\rd, \\rd, -(\\offset)
    .endif
#else
        ldr             \\rd, =\\val+\\offset
#endif
.endm

#define GLUE(a, b) a ## b"""
    if needle not in asm_text:
        raise SystemExit("Could not locate movrel macro insertion point in asm.S")
    asm.write_text(asm_text.replace(needle, macro, 1))

tx_text = tx.read_text()
old_tx = r"movrel          \re, X(ff_tx_tab_\len\()_float)"
new_tx = r"movrelx         \re, X(ff_tx_tab_\len\()_float)"
if old_tx in tx_text:
    tx.write_text(tx_text.replace(old_tx, new_tx, 1))
elif new_tx not in tx_text:
    raise SystemExit("Could not locate ff_tx_tab movrel in tx_float_neon.S")
PYTHON
fi
