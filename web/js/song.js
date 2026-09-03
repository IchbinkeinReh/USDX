// Liest das UltraStar-Liedformat (.txt).
//
// Deckungsgleich mit src/base/USong.pas gehalten - die Dateien sollen in
// beiden Fassungen des Spiels gleich klingen. Die beiden Stellen, an denen
// man sich sicher vertut:
//
//   * #BPM aus der Datei wird intern MIT VIER MULTIPLIZIERT. USDX rechnet in
//     Vierteln (USong.pas: BPM := Wert * Mult * 4). Ohne das liegt alles um
//     den Faktor vier daneben.
//   * Eine Note mit Laenge 0 wird zu einer Freestyle-Note, nicht verworfen.
//
// Notenzeile:  <Typ> <Startschlag> <Laenge> <Tonhoehe> <Text>
// Typen:       ':' normal, '*' golden, 'F' freestyle, 'R' Rap, 'G' Rap golden
// '-' <Schlag> beginnt eine neue Zeile, 'E' beendet das Lied.

export const NOTE_NORMAL = 'normal';
export const NOTE_GOLDEN = 'golden';
export const NOTE_FREESTYLE = 'freestyle';
export const NOTE_RAP = 'rap';
export const NOTE_RAP_GOLDEN = 'rapgolden';

const TYPES = {
  ':': NOTE_NORMAL,
  '*': NOTE_GOLDEN,
  'F': NOTE_FREESTYLE,
  'R': NOTE_RAP,
  'G': NOTE_RAP_GOLDEN,
};

// Freestyle-Noten zaehlen nicht fuer die Wertung - das ist in USDX so, und
// die Weboberflaeche darf davon nicht abweichen.
export function countsForScore(type) {
  return type !== NOTE_FREESTYLE;
}

// Golden zaehlt doppelt.
export function noteFactor(type) {
  return (type === NOTE_GOLDEN || type === NOTE_RAP_GOLDEN) ? 2 : 1;
}

export class Song {
  constructor() {
    this.headers = {};
    this.lines = [];      // [{ startBeat, notes: [...] }]
    this.bpm = 0;         // bereits mal vier, also wie USDX intern rechnet
    this.gap = 0;         // Millisekunden
  }

  get title()  { return this.headers.TITLE || ''; }
  get artist() { return this.headers.ARTIST || ''; }
  get audio()  { return this.headers.AUDIO || this.headers.MP3 || ''; }
  get video()  { return this.headers.VIDEO || ''; }

  // Schlag -> Sekunden. Dieselbe Formel wie UNote.GetTimeFromBeat.
  beatToTime(beat) {
    if (!(this.bpm >= 1)) return 0;
    return this.gap / 1000 + (beat * 60) / this.bpm;
  }

  timeToBeat(seconds) {
    if (!(this.bpm >= 1)) return 0;
    return ((seconds - this.gap / 1000) * this.bpm) / 60;
  }

  get notes() {
    return this.lines.flatMap((l) => l.notes);
  }

  // Hoechstpunktzahl, gegen die gewertet wird.
  get maxNoteValue() {
    return this.notes
      .filter((n) => countsForScore(n.type))
      .reduce((sum, n) => sum + n.length * noteFactor(n.type), 0);
  }
}

function parseNumber(text) {
  // Liedautoren schreiben Kommazahlen mal mit Punkt, mal mit Komma.
  const value = parseFloat(String(text).replace(',', '.'));
  return Number.isFinite(value) ? value : 0;
}

export function parseSong(text) {
  const song = new Song();
  const lines = String(text).split(/\r?\n/);
  let current = null;   // aktuelle Zeile
  let duetWarned = false;

  const beginLine = (startBeat) => {
    current = { startBeat, notes: [] };
    song.lines.push(current);
  };

  for (const raw of lines) {
    const line = raw.trimEnd();
    if (line === '') continue;

    if (line.startsWith('#')) {
      const sep = line.indexOf(':');
      if (sep > 1) {
        const key = line.slice(1, sep).trim().toUpperCase();
        song.headers[key] = line.slice(sep + 1).trim();
      }
      continue;
    }

    const type = line[0];

    if (type === 'E') break;

    if (type === 'P') {
      // Duette haben zwei Spuren. Diese Fassung singt nur die erste; alles
      // andere waere ein halbes Duett, und das ist schlechter als ein
      // ehrliches "wird nicht unterstuetzt".
      if (!duetWarned) {
        song.duet = true;
        duetWarned = true;
      }
      continue;
    }

    if (type === '-') {
      const parts = line.slice(1).trim().split(/\s+/);
      beginLine(parseInt(parts[0], 10) || 0);
      continue;
    }

    if (!(type in TYPES)) continue;   // unbekannte Zeile still uebergehen

    // Text darf Leerzeichen enthalten, deshalb nur dreimal trennen.
    const rest = line.slice(1).replace(/^\s+/, '');
    const m = rest.match(/^(-?\d+)\s+(-?\d+)\s+(-?\d+)\s?(.*)$/);
    if (!m) continue;

    const start = parseInt(m[1], 10);
    const length = parseInt(m[2], 10);
    const pitch = parseInt(m[3], 10);
    const lyric = m[4] === undefined ? '' : m[4];

    if (current === null) beginLine(start);

    song.lines[song.lines.length - 1].notes.push({
      // Laenge 0 -> Freestyle, genau wie in USong.pas.
      type: length === 0 ? NOTE_FREESTYLE : TYPES[type],
      start,
      length,
      pitch,
      text: lyric,
    });
  }

  song.bpm = parseNumber(song.headers.BPM) * 4;   // siehe Kopfkommentar
  song.gap = parseNumber(song.headers.GAP);

  // Leere Zeilen (etwa ein '-' am Ende) stoeren nur beim Anzeigen.
  song.lines = song.lines.filter((l) => l.notes.length > 0);

  return song;
}
