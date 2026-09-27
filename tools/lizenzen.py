#!/usr/bin/python3
"""Baut web/lizenzen.json - die Lizenzen, die die Seite "Impressum &
Datenschutz" unter "Lizenzen" zeigt.

Aufgefuehrt ist das Projekt selbst und jede Bibliothek, die der Server
DIREKT einbindet. Deren eigene Abhaengigkeiten (die lange Liste aus ldd,
von libX11 bis libzstd) stehen nicht einzeln da - sie gehoeren zu den
Bibliotheken bzw. zum Betriebssystem, nicht zu diesem Projekt. Die
Weboberflaeche selbst bindet keine fremden Bibliotheken ein: Alles unter
web/js ist eigener Code.

Die Texte kommen aus dem Quellbaum (game/LICENSE.*.txt, LICENSE) und aus
tools/lizenzen/ fuer das, was dort fehlt. Neue Bibliothek: hier eintragen,
Skript laufen lassen, Ergebnis mit einchecken.

Aufruf:

    tools/lizenzen.py            # web/lizenzen.json neu schreiben
    tools/lizenzen.py --pruefe   # nur pruefen, ob sie aktuell ist (Tests)
"""

import json
import os
import sys

WURZEL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIEL = os.path.join(WURZEL, 'web', 'lizenzen.json')

# name, wofuer, lizenz, adresse, datei (relativ zur Wurzel)
LIZENZEN = [
    ('UltraStar Deluxe', 'dieses Projekt - Spiel, Server und Weboberfläche',
     'GNU General Public License 2.0',
     'https://github.com/UltraStar-Deluxe/USDX', 'LICENSE'),
    ('Free Pascal RTL und FCL', 'Laufzeitbibliothek, HTTP-Server, JSON',
     'modifizierte GNU LGPL 2.1 (mit Ausnahme für das Einbinden)',
     'https://www.freepascal.org/', 'tools/lizenzen/fpc-rtl.txt'),
    ('SDL2', 'Fenster, Eingabe, Grundgerüst des Spiels', 'zlib-Lizenz',
     'https://www.libsdl.org/', 'game/LICENSE.sdl2.txt'),
    ('SDL2_image', 'Laden von Titel- und Hintergrundbildern', 'zlib-Lizenz',
     'https://github.com/libsdl-org/SDL_image', 'game/LICENSE.sdl2_image.txt'),
    ('FFmpeg', 'Ton und Video lesen, Vorschau-Schnipsel', 'GNU LGPL',
     'https://ffmpeg.org/', 'game/LICENSE.ffmpeg.txt'),
    ('FreeType', 'Schriftdarstellung im Spiel',
     'FreeType-Lizenz oder GNU GPL 2.0 (hier der GPL-Text)',
     'https://freetype.org/', 'game/LICENSE.freetype.txt'),
    ('Lua', 'Skripte im Spiel (Party-Modi)', 'MIT-Lizenz',
     'https://www.lua.org/', 'game/LICENSE.lua.txt'),
    ('SQLite', 'Bestenliste und Statistik im Spiel', 'gemeinfrei (Public Domain)',
     'https://sqlite.org/', 'game/LICENSE.sqlite.txt'),
    ('PortAudio', 'Mikrofonaufnahme im Spiel', 'MIT-Lizenz',
     'https://www.portaudio.com/', 'game/LICENSE.portaudio.txt'),
    ('zlib', 'Kompression (über SDL2_image)', 'zlib-Lizenz',
     'https://www.zlib.net/', 'game/LICENSE.zlib.txt'),
    ('libpng', 'PNG-Bilder (über SDL2_image)', 'libpng-Lizenz',
     'http://www.libpng.org/pub/png/libpng.html', 'game/LICENSE.png.txt'),
    ('libjpeg-turbo', 'JPEG-Bilder (über SDL2_image)', 'IJG- und BSD-Lizenz',
     'https://libjpeg-turbo.org/', 'game/LICENSE.libjpeg-turbo.txt'),
    ('libtiff', 'TIFF-Bilder (über SDL2_image)', 'libtiff-Lizenz',
     'http://www.simplesystems.org/libtiff/', 'game/LICENSE.tiff.txt'),
    ('libwebp', 'WebP-Bilder (über SDL2_image)', 'BSD-Lizenz',
     'https://developers.google.com/speed/webp', 'game/LICENSE.webp.txt'),
    ('dav1d', 'AV1-Video (über FFmpeg)', 'BSD-Lizenz (2 Klauseln)',
     'https://code.videolan.org/videolan/dav1d', 'game/LICENSE.libdav1d.txt'),
]


def baue():
    eintraege = []
    for name, zweck, lizenz, adresse, datei in LIZENZEN:
        with open(os.path.join(WURZEL, datei), encoding='utf-8', errors='replace') as f:
            text = f.read().replace('\r\n', '\n').strip() + '\n'
        eintraege.append({'name': name, 'zweck': zweck, 'lizenz': lizenz,
                          'adresse': adresse, 'text': text})
    # Fest sortiert und ohne Zeitstempel: So ist die Datei bei gleichen
    # Quellen Byte fuer Byte gleich, und --pruefe kann vergleichen.
    return json.dumps({'lizenzen': eintraege}, ensure_ascii=False, indent=1) + '\n'


def main():
    neu = baue()
    if '--pruefe' in sys.argv[1:]:
        try:
            with open(ZIEL, encoding='utf-8') as f:
                alt = f.read()
        except OSError:
            alt = ''
        if alt != neu:
            print('web/lizenzen.json ist veraltet - tools/lizenzen.py laufen lassen.')
            return 1
        print('web/lizenzen.json ist aktuell.')
        return 0
    with open(ZIEL, 'w', encoding='utf-8') as f:
        f.write(neu)
    print(f'{ZIEL}: {len(LIZENZEN)} Lizenzen')
    return 0


if __name__ == '__main__':
    sys.exit(main())
