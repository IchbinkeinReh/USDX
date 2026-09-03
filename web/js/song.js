// Liest das UltraStar-Liedformat (.txt).
//
// Deckungsgleich mit src/base/USong.pas gehalten - die Dateien sollen in
// beiden Fassungen des Spiels gleich klingen. Die Stellen, an denen man sich
// sicher vertut:
//
//   * #BPM aus der Datei wird intern MIT VIER MULTIPLIZIERT. USDX rechnet in
//     Vierteln (USong.pas: BPM := Wert * Mult * 4). Ohne das liegt alles um
//     den Faktor vier daneben.
//   * Eine Note mit Laenge 0 wird zu einer Freestyle-Note, nicht verworfen.
//   * Im Relativmodus zaehlt der Versatz JE SPUR (USong.pas: Rel[CurrentTrack]).
//     Ein gemeinsamer Zaehler laesst die zweite Stimme im Duett wandern.
//
// Notenzeile:  <Typ> <Startschlag> <Laenge> <Tonhoehe> <Text>
// Typen:       ':' normal, '*' golden, 'F' freestyle, 'R' Rap, 'G' Rap golden
// '-' <Schlag> [<Versatz>] beginnt eine neue Zeile, 'E' beendet das Lied.
// 'P1'/'P2' schalten im Duett auf die erste bzw. zweite Stimme um.

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

// Eine Stimme. Beim Solo gibt es genau eine, beim Duett zwei.
export class Track {
  constructor(name) {
    this.name = name;
    this.lines = [];      // [{ startBeat, notes: [...] }]
  }

  get notes() {
    return this.lines.flatMap((l) => l.notes);
  }

  // Hoechstpunktzahl, gegen die diese Stimme gewertet wird.
  get maxNoteValue() {
    return this.notes
      .filter((n) => countsForScore(n.type))
      .reduce((sum, n) => sum + n.length * noteFactor(n.type), 0);
  }
}

export class Song {
  constructor() {
    this.headers = {};
    this.tracks = [];
    this.isDuet = false;
    this.bpm = 0;         // bereits mal vier, also wie USDX intern rechnet
    this.gap = 0;         // Millisekunden
  }

  get title()  { return this.headers.TITLE || ''; }
  get artist() { return this.headers.ARTIST || ''; }
  get audio()  { return this.headers.AUDIO || this.headers.MP3 || ''; }
  get video()  { return this.headers.VIDEO || ''; }
  get background() { return this.headers.BACKGROUND || ''; }

  // #VIDEOGAP in Sekunden. Im Spiel gilt: Videoposition = VIDEOGAP + Tonzeit
  // (UScreenSingController). Ein falsches Vorzeichen verschiebt das Bild
  // gegen den Ton, ohne dass sonst etwas auffiele.
  get videoGap() { return parseNumber(this.headers.VIDEOGAP); }

  // Die Namen der Stimmen, in der Reihenfolge der Spuren.
  get singerNames() { return this.tracks.map((t) => t.name); }

  track(index) { return this.tracks[index] || this.tracks[0]; }

  // Schlag -> Sekunden. Dieselbe Formel wie UNote.GetTimeFromBeat.
  beatToTime(beat) {
    if (!(this.bpm >= 1)) return 0;
    return this.gap / 1000 + (beat * 60) / this.bpm;
  }

  timeToBeat(seconds) {
    if (!(this.bpm >= 1)) return 0;
    return ((seconds - this.gap / 1000) * this.bpm) / 60;
  }

  // Diese drei beziehen sich auf die erste Stimme. Beim Solo ist das die
  // einzige, beim Duett muss man sich bewusst fuer eine Spur entscheiden -
  // deshalb nehmen Wertung und Anzeige eine Spur entgegen, nicht das Lied.
  get lines()        { return this.tracks[0] ? this.tracks[0].lines : []; }
  get notes()        { return this.tracks[0] ? this.tracks[0].notes : []; }
  get maxNoteValue() { return this.tracks[0] ? this.tracks[0].maxNoteValue : 0; }
}

function parseNumber(text) {
  // Liedautoren schreiben Kommazahlen mal mit Punkt, mal mit Komma.
  const value = parseFloat(String(text).replace(',', '.'));
  return Number.isFinite(value) ? value : 0;
}

// Wie weit ist eine Silbe gesungen? 0 vor ihr, 1 danach.
//
// Genau die Formel aus ULyrics.pas: Progress := (Beat - CurWord.Start) /
// CurWord.Length, begrenzt auf 0..1. Danach richtet sich, wo der Text
// zwischen "schon gesungen" und "kommt noch" geteilt wird.
export function noteProgress(note, beat) {
  if (!note || !(note.length > 0)) return 0;
  const p = (beat - note.start) / note.length;
  if (p <= 0) return 0;
  if (p >= 1) return 1;
  return p;
}

// Welche Zeile gehoert zu diesem Schlag?
//
// Nicht einfach "die letzte, die begonnen hat": Ist eine Zeile
// ausgesungen, wird auf die naechste umgeschaltet, auch wenn deren Einsatz
// noch bevorsteht. Sonst bliebe der ausgesungene Text stehen und der
// Vorlauf zaehlte auf einen Einsatz herunter, der laengst vorbei ist.
export function lineAt(track, beat) {
  const lines = track && track.lines ? track.lines : [];
  if (lines.length === 0) return null;

  let index = 0;
  for (let i = 0; i < lines.length; i++) {
    if (beat >= lines[i].startBeat) index = i;
    else break;
  }

  const letzte = lines[index].notes[lines[index].notes.length - 1];
  if (letzte && beat >= letzte.start + letzte.length && index + 1 < lines.length)
    return lines[index + 1];

  return lines[index];
}

// Sekunden, bis die erste Note dieser Zeile faellig ist.
// Negativ, wenn die Zeile schon laeuft. null, wenn es nichts zu warten gibt.
export function secondsUntilLine(song, line, seconds) {
  if (!song || !line || !line.notes || line.notes.length === 0) return null;
  return song.beatToTime(line.notes[0].start) - seconds;
}

// Liest die Nummer aus einem Spurwechsel. "P1" und "P 1" sind beide erlaubt.
function parsePlayerNumber(line) {
  const m = line.match(/^P\s*(\d+)/);
  return m ? parseInt(m[1], 10) : NaN;
}

export function parseSong(text) {
  const song = new Song();
  const lines = String(text).split(/\r?\n/);

  // Ob das Lied ein Duett ist, entscheidet USDX an der ERSTEN Zeile des
  // Notenteils: Faengt sie mit P an, ist es eines. Ein spaeterer Spurwechsel
  // in einem Sololied ist dort ein Fehler - und hier auch, sonst saenge man
  // stillschweigend zwei Stimmen durcheinander.
  let firstNoteLineSeen = false;
  let current = null;          // aktuelle Zeile innerhalb der Spur
  let currentTrack = 0;
  let relative = false;
  const rel = [0, 0];          // Versatz je Spur, siehe Kopfkommentar

  const trackOf = (index) => {
    while (song.tracks.length <= index) {
      song.tracks.push(new Track('P' + (song.tracks.length + 1)));
    }
    return song.tracks[index];
  };

  const beginLine = (startBeat) => {
    current = { startBeat, notes: [] };
    trackOf(currentTrack).lines.push(current);
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

    if (!firstNoteLineSeen) {
      firstNoteLineSeen = true;
      relative = /^(yes|true|1)$/i.test(song.headers.RELATIVE || '');
      if (type === 'P') {
        song.isDuet = true;
        trackOf(1);            // beide Spuren anlegen, auch wenn eine leer bleibt
      }
    }

    if (type === 'E') break;

    if (type === 'P') {
      if (!song.isDuet) {
        throw new Error(
          'Spurwechsel "' + line + '" in einem Sololied. P1/P2 sind nur ' +
          'erlaubt, wenn schon die erste Zeile des Notenteils eine P-Zeile ist.');
      }
      const nummer = parsePlayerNumber(line);
      if (nummer !== 1 && nummer !== 2) {
        // USDX lehnt das Lied hier ab. Stillschweigend weiterzusingen waere
        // schlechter: Die Noten landeten in der falschen Stimme.
        throw new Error('Unbekannte Spurnummer in "' + line + '"');
      }
      currentTrack = nummer - 1;
      trackOf(currentTrack);
      current = null;          // die neue Spur faengt ihre Zeilen selbst an
      continue;
    }

    if (type === '-') {
      const parts = line.slice(1).trim().split(/\s+/);
      const param1 = parseInt(parts[0], 10) || 0;
      // Im Relativmodus beginnt die Zeile beim bisherigen Versatz, und erst
      // danach waechst er um den zweiten Wert - genau in dieser Reihenfolge
      // (USong.pas: NewSentence).
      beginLine(param1 + (relative ? rel[currentTrack] : 0));
      if (relative && parts.length > 1) {
        rel[currentTrack] += parseInt(parts[1], 10) || 0;
      }
      continue;
    }

    if (!(type in TYPES)) continue;   // unbekannte Zeile still uebergehen

    // Text darf Leerzeichen enthalten, deshalb nur dreimal trennen.
    const rest = line.slice(1).replace(/^\s+/, '');
    const m = rest.match(/^(-?\d+)\s+(-?\d+)\s+(-?\d+)\s?(.*)$/);
    if (!m) continue;

    const start = parseInt(m[1], 10) + (relative ? rel[currentTrack] : 0);
    const length = parseInt(m[2], 10);
    const pitch = parseInt(m[3], 10);
    const lyric = m[4] === undefined ? '' : m[4];

    if (current === null) beginLine(start);

    current.notes.push({
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

  if (song.tracks.length === 0) trackOf(0);

  // Namen der Saenger. #P1/#P2 ist die heutige Schreibweise, #DUETSINGERP1
  // die alte; USDX liest beide, also lesen wir beide.
  const namen = [
    song.headers.P1 || song.headers.DUETSINGERP1,
    song.headers.P2 || song.headers.DUETSINGERP2,
  ];
  song.tracks.forEach((t, i) => {
    if (namen[i]) t.name = namen[i];
  });

  // Leere Zeilen (etwa ein '-' am Ende) stoeren nur beim Anzeigen.
  for (const t of song.tracks) {
    t.lines = t.lines.filter((l) => l.notes.length > 0);
  }
  // Eine Spur ohne jede Note ist keine - das kommt vor, wenn ein Lied als
  // Duett angelegt, die zweite Stimme aber nie gefuellt wurde.
  if (song.isDuet && song.tracks.length > 1 &&
      song.tracks[1].lines.length === 0) {
    song.tracks.length = 1;
    song.isDuet = false;
  }

  return song;
}
