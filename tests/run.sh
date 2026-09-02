#!/bin/sh
# Baut und startet die Testprogramme.
#
# Die Schalter muessen zu denen des Spiels passen (siehe src/Makefile,
# PFLAGS_*): Weichen sie ab, haelt fpc die bereits gebauten Units fuer
# unbrauchbar und compiliert das halbe Spiel neu - mitsamt SDL, das hier
# gar nicht gebraucht wird.
#
# Voraussetzung: "make" wurde einmal ausgefuehrt, die .ppu liegen also in
# build/fpc-x86_64-linux.
set -eu

cd "$(dirname "$0")/.."
UNITS="build/fpc-$(fpc -iTP)-$(fpc -iTO)"

if [ ! -d "$UNITS" ]; then
    echo "Erst 'make' ausfuehren - $UNITS fehlt." >&2
    exit 1
fi

FLAGS="-Si -Sg- -Sc- -v0Binwe -Ciro -gl -Xs- -O2 -OoNOSTACKFRAME -dUseMidiEmu"
mkdir -p tests/build

FEHLER=0
for QUELLE in tests/test*.pas; do
    NAME="${QUELLE%.pas}"
    echo "=== $(basename "$NAME") ==="
    # shellcheck disable=SC2086
    fpc $FLAGS -Fu"$UNITS" -Fisrc -FUtests/build -o"$NAME" "$QUELLE" \
        > "tests/build/$(basename "$NAME").log" 2>&1 || {
            echo "  Bau fehlgeschlagen:"
            grep -iE "error|fatal" "tests/build/$(basename "$NAME").log" | head -5
            FEHLER=1
            continue
        }
    "./$NAME" || FEHLER=1
done
exit $FEHLER
