#!/bin/sh
# Startet das gebaute Spiel im kopflosen Webbetrieb und spricht es an.
#
# Der einzige Test, der den ganzen Weg abdeckt: Befehlszeile, Abzweigung vor
# Main, Ordnersuche, Kopfdaten, Server, Dateien. Die Pascal-Tests pruefen die
# Teile einzeln - dass sie auch zusammen laufen, zeigt erst dieser hier.
#
# Wichtig ist dabei, was NICHT passiert: kein Fenster, kein OpenGL. Liefe das
# Programm doch in die Grafikinitialisierung, kaeme es hier gar nicht erst
# bis zur ersten Antwort.
set -u

cd "$(dirname "$0")/.."
SPIEL="game/ultrastardx"
PORT=8171

if [ ! -x "$SPIEL" ]; then
    echo "  $SPIEL fehlt - uebersprungen"
    exit 0
fi
if ! command -v curl > /dev/null 2>&1; then
    echo "  curl fehlt - uebersprungen"
    exit 0
fi

BESTANDEN=0
FEHLGESCHLAGEN=0

pruefe() {
    if [ "$2" = "$3" ]; then
        BESTANDEN=$((BESTANDEN + 1))
        echo "  OK   $1"
    else
        FEHLGESCHLAGEN=$((FEHLGESCHLAGEN + 1))
        echo "  FEHL $1  erwartet '$3', bekommen '$2'"
    fi
}

ORDNER=$(mktemp -d)
LOG="$ORDNER/lauf.log"
mkdir -p "$ORDNER/lieder/Solo" "$ORDNER/lieder/Duo"

printf '#TITLE:Solo\n#ARTIST:Einer\n#YEAR:1976\n#MP3:t.mp3\n#BPM:100\n: 0 4 60 a\nE\n' \
    > "$ORDNER/lieder/Solo/lied.txt"
printf 'TON' > "$ORDNER/lieder/Solo/t.mp3"
printf '#TITLE:Zusammen\n#ARTIST:Duo\n#BPM:120\n#VIDEO:v.mp4\n#BACKGROUND:b.jpg\n#VIDEOGAP:1.5\nP1\n: 0 4 60 a\nP2\n: 0 4 67 b\nE\n' \
    > "$ORDNER/lieder/Duo/lied.txt"
printf 'VIDEO' > "$ORDNER/lieder/Duo/v.mp4"
printf 'BILD' > "$ORDNER/lieder/Duo/b.jpg"
printf 'kein Lied\n' > "$ORDNER/lieder/liesmich.txt"

# --webhost 127.0.0.1: Der Test prueft gleich mit, dass die Bindung wirkt.
"./$SPIEL" --web-only --webport "$PORT" --webhost 127.0.0.1 \
    --songpath "$ORDNER/lieder" > "$LOG" 2>&1 &
PID=$!

# Warten, bis der Server antwortet - nicht blind schlafen.
BEREIT=0
I=0
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
    cat "$LOG"
    kill "$PID" 2>/dev/null
    rm -rf "$ORDNER"
    exit 1
fi

hole() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }

pruefe "startet ohne Bildschirm" "$BEREIT" "1"

# Hinter einem Vorschalt-Server, der die Anmeldung prueft, MUSS der Dienst
# auf 127.0.0.1 haengen. Lauschte er auf allen Adressen, waere der Port aus
# dem Netz direkt erreichbar und die Anmeldung damit wertlos.
if command -v ss > /dev/null 2>&1; then
    OFFEN=$(ss -ltn 2>/dev/null | grep -c "0.0.0.0:$PORT")
    pruefe "haengt nicht auf allen Adressen" "$OFFEN" "0"
    GEBUNDEN=$(ss -ltn 2>/dev/null | grep -c "127.0.0.1:$PORT")
    pruefe "haengt auf 127.0.0.1" "$GEBUNDEN" "1"
fi
pruefe "Status antwortet" "$(hole /api/status)" "200"
pruefe "Oberflaeche wird ausgeliefert" "$(hole /)" "200"
pruefe "Modul wird ausgeliefert" "$(hole /js/song.js)" "200"

ANZAHL=$(curl -s "http://127.0.0.1:$PORT/api/songs" | grep -o '"index"' | wc -l)
pruefe "beide Lieder gefunden, die Liesmich nicht" "$(echo "$ANZAHL" | tr -d ' ')" "2"

DUETTE=$(curl -s "http://127.0.0.1:$PORT/api/songs" | grep -o '"duet" : true' | wc -l)
pruefe "genau ein Duett erkannt" "$(echo "$DUETTE" | tr -d ' ')" "1"

pruefe "Lieddatei abrufbar" "$(hole /api/song/0/txt)" "200"

# Welcher Eintrag das Duett ist, haengt an der Reihenfolge der Ordner.
# Deshalb suchen statt raten.
DUETT=$(curl -s "http://127.0.0.1:$PORT/api/songs" \
        | tr '}' '\n' | grep '"duet" : true' | grep -o '"index" : [0-9]*' \
        | grep -o '[0-9]*')
SOLO=$(curl -s "http://127.0.0.1:$PORT/api/songs" \
       | tr '}' '\n' | grep '"duet" : false' | grep -o '"index" : [0-9]*' \
       | grep -o '[0-9]*')

pruefe "Video wird ausgeliefert" "$(hole "/api/song/$DUETT/video")" "200"
pruefe "Hintergrundbild wird ausgeliefert" \
       "$(hole "/api/song/$DUETT/background")" "200"

TYP=$(curl -s -o /dev/null -w '%{content_type}' \
      "http://127.0.0.1:$PORT/api/song/$DUETT/video")
pruefe "Video mit passendem Typ" "$TYP" "video/mp4"
TYP=$(curl -s -o /dev/null -w '%{content_type}' \
      "http://127.0.0.1:$PORT/api/song/$DUETT/background")
pruefe "Bild mit passendem Typ" "$TYP" "image/jpeg"

# Ohne Video muss 404 kommen: Der Browser fragt immer erst an und faellt
# genau darauf zurueck. Eine leere 200-Antwort haette er als kaputtes Video
# verstanden und gar nichts angezeigt.
pruefe "Lied ohne Video antwortet mit 404" "$(hole "/api/song/$SOLO/video")" "404"
pruefe "Lied ohne Bild antwortet mit 404" \
       "$(hole "/api/song/$SOLO/background")" "404"
pruefe "unbekanntes Lied wird abgewiesen" "$(hole /api/song/99/txt)" "404"
pruefe "Ausbruch aus dem Webordner scheitert" "$(hole /js/../../etc/passwd)" "404"

# Beenden muss klappen: Ein Dienst, der sich nicht stoppen laesst, ist auf
# einem Server schlimmer als einer, der gar nicht erst startet.
kill -TERM "$PID" 2>/dev/null
I=0
while [ $I -lt 25 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    sleep 0.2
    I=$((I + 1))
done
if kill -0 "$PID" 2>/dev/null; then
    kill -9 "$PID" 2>/dev/null
    pruefe "beendet sich auf SIGTERM" "nein" "ja"
else
    pruefe "beendet sich auf SIGTERM" "ja" "ja"
fi

rm -rf "$ORDNER"
echo
echo "$BESTANDEN bestanden, $FEHLGESCHLAGEN fehlgeschlagen"
[ "$FEHLGESCHLAGEN" -eq 0 ]
