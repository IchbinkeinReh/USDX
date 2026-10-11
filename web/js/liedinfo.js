// Alles, was ueber ein Lied bekannt ist - fuer die Ansicht beim Anhalten.
//
// Angezeigt wird jede Kopfzeile der Notendatei: zuerst die, die Menschen
// interessieren (Interpret, Titel, Genre, ...), dann die technischen. Was
// hier keinen deutschen Namen hat, erscheint unter seinem eigenen - lieber
// "#MEINFELD" als gar nicht.

const UEBER = [
  ['ARTIST', 'Interpret'], ['TITLE', 'Titel'], ['ALBUM', 'Album'],
  ['GENRE', 'Genre'], ['YEAR', 'Jahr'], ['LANGUAGE', 'Sprache'],
  ['EDITION', 'Edition'], ['TAGS', 'Schlagwörter'],
  ['P1', 'Stimme 1'], ['DUETSINGERP1', 'Stimme 1'],
  ['P2', 'Stimme 2'], ['DUETSINGERP2', 'Stimme 2'],
  ['CREATOR', 'Erstellt von'], ['AUTHOR', 'Autor'],
  ['PROVIDEDBY', 'Bereitgestellt von'], ['COMMENT', 'Kommentar'],
];

const TECHNIK = [
  ['BPM', 'BPM'], ['GAP', 'GAP (ms)'], ['START', 'Start (s)'], ['END', 'Ende (ms)'],
  ['VIDEOGAP', 'Video-Versatz (s)'], ['PREVIEWSTART', 'Vorschau ab (s)'],
  ['MEDLEYSTARTBEAT', 'Medley-Anfang (Schlag)'], ['MEDLEYENDBEAT', 'Medley-Ende (Schlag)'],
  ['CALCMEDLEY', 'Medley berechnen'],
  ['MP3', 'Tondatei'], ['AUDIO', 'Tondatei'], ['VOCALS', 'Gesangsspur'],
  ['INSTRUMENTAL', 'Instrumentalspur'], ['VIDEO', 'Video'], ['COVER', 'Titelbild'],
  ['BACKGROUND', 'Hintergrund'], ['VERSION', 'Formatversion'],
  ['ENCODING', 'Zeichensatz'], ['RELATIVE', 'Relative Zeiten'],
  ['RESOLUTION', 'Auflösung'], ['NOTESGAP', 'Notenabstand'],
];

// { ueber: [{ schluessel, name, wert }], technik: [...] } - leere Felder fallen weg.
export function liedAngaben(song) {
  const h = (song && song.headers) || {};
  const genommen = new Set();
  const nimm = (liste) => liste
    .filter(([k]) => h[k] !== undefined && String(h[k]).trim() !== '' && !genommen.has(k))
    .map(([k, name]) => { genommen.add(k); return { schluessel: k, name, wert: h[k] }; });
  const ueber = nimm(UEBER);
  const technik = nimm(TECHNIK);
  for (const k of Object.keys(h).sort()) {
    if (!genommen.has(k) && String(h[k]).trim() !== '')
      technik.push({ schluessel: k, name: '#' + k, wert: h[k] });
  }
  return { ueber, technik };
}

// Der Liedtext zum Lesen: je Stimme die Zeilen als Text. "~" markiert im
// Format eine gehaltene Silbe und gehoert nicht zum Wort - "Pro~be~ton"
// liest sich als "Probeton". Beim Duett traegt jede Stimme ihren Namen.
export function liedtext(song) {
  if (!song || !Array.isArray(song.tracks)) return [];
  return song.tracks.map((spur) => ({
    name: song.isDuet ? spur.name : null,
    zeilen: spur.lines
      .map((z) => z.notes.map((n) => n.text || '').join('')
        .replace(/~/g, '').replace(/\s+/g, ' ').trim())
      .filter((z) => z !== ''),
  })).filter((s) => s.zeilen.length > 0);
}
