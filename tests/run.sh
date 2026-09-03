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

# Vor den Tests neu bauen. Ohne das nimmt fpc die alten .ppu aus $UNITS, und
# die Tests pruefen dann eine Fassung des Codes, die es nicht mehr gibt -
# einmal grün, obwohl die Aenderung gar nicht drin ist.
echo "=== Bau ==="
if ! make > tests/build-make.log 2>&1; then
    grep -iE "error|fatal" tests/build-make.log | head -10
    echo "Bau fehlgeschlagen - siehe tests/build-make.log" >&2
    exit 1
fi

FLAGS="-Si -Sg- -Sc- -v0Binwe -Ciro -gl -Xs- -O2 -OoNOSTACKFRAME -dUseMidiEmu"
mkdir -p tests/build

FEHLER=0

# Zuerst die statische Pruefung: Sie faengt eine Falle ab, die kein
# Laufzeittest bemerkt, weil das Programm dabei gar nicht erst startet.
echo "=== Namenskollisionen ==="
python3 tests/check_namen.py || FEHLER=1

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

# Das Ganze im Zusammenspiel: das gebaute Spiel kopflos starten und ueber
# HTTP ansprechen. Deckt die Wege ab, die kein Einzeltest erreicht.
echo "=== kopfloser Webbetrieb ==="
sh tests/headless.sh || FEHLER=1

# Der Spielkern der Weboberflaeche liegt in JavaScript und wird dort geprueft.
echo "=== web (JavaScript) ==="
if command -v node > /dev/null 2>&1; then
    node web/tests/run.mjs || FEHLER=1
else
    echo "  node fehlt - uebersprungen"
fi

exit $FEHLER
