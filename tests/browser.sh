#!/bin/sh
# Startet Server und Browser und laesst web/tests/browser.mjs darauf los.
#
# Der einzige Test mit einem echten Browser. Alles andere am Web-Teil laesst
# sich ohne pruefen - der Dienstarbeiter und die Tonausgabe nicht.
#
# Faellt still aus, wenn kein Browser da ist: Ein fehlender Browser ist kein
# Fehlschlag des Codes, und die Sammlung soll auch auf einem Rechner ohne
# durchlaufen.
set -u

cd "$(dirname "$0")/.."

SPIEL="game/ultrastardx"

if [ ! -x "$SPIEL" ]; then
    echo "  $SPIEL fehlt - uebersprungen"
    exit 0
fi
if ! command -v node > /dev/null 2>&1; then
    echo "  node fehlt - uebersprungen"
    exit 0
fi

# Einen Browser suchen, der auch wirklich startet.
#
# Die Reihenfolge ist Absicht: $CHROME schlaegt alles, dann ein eigenstaendig
# geladenes Chrome, dann das System. Auf Rechnern, deren /tmp ein Symlink
# ist, scheitert JEDER streng eingesperrte Snap in snap-confine
# ("cannot create temporary directory for the root file system") - und
# chromium wie firefox sind auf Ubuntu genau das. Deshalb wird nicht nur
# geschaut, ob die Datei da ist, sondern ob sie sich starten laesst.
laeuft() {
    [ -n "$1" ] && [ -x "$1" ] && "$1" --version > /dev/null 2>&1
}

BROWSER=""
for KANDIDAT in \
    "${CHROME:-}" \
    "$HOME"/.cache/puppeteer/chrome/*/chrome-linux64/chrome \
    "$(command -v google-chrome-stable 2>/dev/null)" \
    "$(command -v google-chrome 2>/dev/null)" \
    "$(command -v chromium 2>/dev/null)" \
    "$(command -v chromium-browser 2>/dev/null)"
do
    if laeuft "$KANDIDAT"; then
        BROWSER="$KANDIDAT"
        break
    fi
done

if [ -z "$BROWSER" ]; then
    echo "  kein startbarer Browser gefunden - uebersprungen"
    echo "  (einen holen: npx -y @puppeteer/browsers install chrome@stable \\"
    echo "     --path \"\$HOME/.cache/puppeteer\")"
    exit 0
fi

# Freien Port suchen, statt einen festen zu nehmen: Auf dem Entwicklungs-
# rechner laeuft womoeglich schon ein echter Dienst.
frei() {
    ss -ltn 2>/dev/null | grep -q ":$1 " && return 1
    return 0
}
PORT=""
CDPPORT=""
P=8180
while [ $P -lt 8260 ]; do
    if frei $P; then PORT=$P; break; fi
    P=$((P + 1))
done
P=9250
while [ $P -lt 9330 ]; do
    if frei $P; then CDPPORT=$P; break; fi
    P=$((P + 1))
done
if [ -z "$PORT" ] || [ -z "$CDPPORT" ]; then
    echo "  kein freier Port - uebersprungen"
    exit 0
fi

ORDNER=$(mktemp -d)
SPIELPID=""
BROWSERPID=""

# Das Probelied in den Wegwerfordner kopieren, nicht am Ort benutzen.
#
# Der Server schneidet beim Start einen Vorschau-Schnipsel NEBEN die
# Tondatei. Liefe der Test auf tests/probelied, laege danach eine erzeugte
# Datei im Arbeitsverzeichnis - und beim naechsten git status im Weg.
LIEDER="$ORDNER/lieder"
mkdir -p "$LIEDER/Probe"
cp tests/probelied/lied.txt tests/probelied/ton.mp3 \
   "tests/probelied/ton [INSTR].m4a" "$LIEDER/Probe/"

# Immer per PID beenden, nie mit pkill ueber den Programmnamen: Auf einem
# Rechner, auf dem der Dienst selbst laeuft, traefe ein Muster wie
# "ultrastardx --web-only" den echten Dienst mit.
aufraeumen() {
    [ -n "$BROWSERPID" ] && kill "$BROWSERPID" 2>/dev/null
    [ -n "$SPIELPID" ] && kill "$SPIELPID" 2>/dev/null
    # Dem Browser Zeit zum Schliessen lassen: Er schreibt sein Profil beim
    # Beenden noch fertig, und ein rm mitten hinein scheitert an Dateien,
    # die gerade erst entstehen.
    I=0
    while [ $I -lt 20 ]; do
        kill -0 "$BROWSERPID" 2>/dev/null || break
        sleep 0.1
        I=$((I + 1))
    done
    rm -rf "$ORDNER" 2>/dev/null
}
trap aufraeumen EXIT INT TERM

# 127.0.0.1 ist nicht beliebig: Dienstarbeiter gibt es nur im sicheren
# Kontext, und localhost gilt als sicher. Ueber die Netzadresse desselben
# Rechners wuerde sich gar keiner anmelden.
"./$SPIEL" --web-only --webport "$PORT" --webhost 127.0.0.1 \
    --songpath "$LIEDER" > "$ORDNER/server.log" 2>&1 &
SPIELPID=$!

I=0
BEREIT=0
while [ $I -lt 50 ]; do
    if curl -s -o /dev/null "http://127.0.0.1:$PORT/api/status" 2>/dev/null; then
        BEREIT=1
        break
    fi
    sleep 0.2
    I=$((I + 1))
done
if [ $BEREIT -eq 0 ]; then
    echo "  FEHL Server ist nicht hochgekommen"
    cat "$ORDNER/server.log"
    exit 1
fi

# --no-sandbox: Der Sandkasten braucht Benutzer-Namensraeume, die in
# Baucontainern oft fehlen. Hier laeuft nur unsere eigene Testseite.
"$BROWSER" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --autoplay-policy=no-user-gesture-required \
    --remote-debugging-port="$CDPPORT" \
    --user-data-dir="$ORDNER/browser" about:blank \
    > "$ORDNER/browser.log" 2>&1 &
BROWSERPID=$!

I=0
BEREIT=0
while [ $I -lt 50 ]; do
    if curl -s -o /dev/null "http://127.0.0.1:$CDPPORT/json/version" 2>/dev/null; then
        BEREIT=1
        break
    fi
    sleep 0.2
    I=$((I + 1))
done
if [ $BEREIT -eq 0 ]; then
    echo "  FEHL Browser ist nicht hochgekommen"
    tail -5 "$ORDNER/browser.log"
    exit 1
fi

node web/tests/browser.mjs "http://127.0.0.1:$PORT" "http://127.0.0.1:$CDPPORT"
