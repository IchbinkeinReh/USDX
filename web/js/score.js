// Wertung.
//
// Nachgebildet nach dem Modell von USDX: Jede Note traegt so viel bei, wie
// sie lang ist, goldene Noten doppelt, Freestyle gar nicht. Die Punktzahl
// ist der erreichte Anteil an der Gesamtsumme, hochgerechnet auf 10000.
//
// Bewusst NICHT sample-genau wie im Spiel: Die Weboberflaeche bekommt vom
// Browser Bloecke von einigen Millisekunden, nicht einzelne Abtastwerte.
// Gewertet wird deshalb je Block, und die Note bekommt den Anteil der
// Bloecke, in denen richtig getroffen wurde.

import { countsForScore, noteFactor } from './song.js';
import { sameTone } from './pitch.js';

export const MAX_SCORE = 10000;

export class Scorer {
  constructor(song) {
    this.song = song;
    this.maxValue = song.maxNoteValue;
    // Je Note: wie viele Treffer und wie viele Versuche.
    this.state = new Map();
  }

  // Meldet eine gemessene Tonhoehe zu einem Zeitpunkt.
  // sungMidi < 0 bedeutet "nichts erkannt" - zaehlt als Versuch ohne Treffer.
  feed(seconds, sungMidi) {
    const note = this.noteAt(seconds);
    if (!note || !countsForScore(note.type)) return null;

    let s = this.state.get(note);
    if (!s) {
      s = { hits: 0, tries: 0 };
      this.state.set(note, s);
    }
    s.tries++;
    const treffer = sameTone(sungMidi, note.pitch + 60);
    if (treffer) s.hits++;
    return treffer;
  }

  // Welche Note ist zu diesem Zeitpunkt zu singen? null in den Pausen.
  noteAt(seconds) {
    const beat = this.song.timeToBeat(seconds);
    for (const note of this.song.notes) {
      if (beat >= note.start && beat < note.start + note.length) return note;
    }
    return null;
  }

  get score() {
    if (!(this.maxValue > 0)) return 0;
    let erreicht = 0;
    for (const [note, s] of this.state) {
      if (s.tries === 0) continue;
      // Anteil der getroffenen Bloecke, gewichtet wie die Note selbst.
      erreicht += (s.hits / s.tries) * note.length * noteFactor(note.type);
    }
    return Math.round((erreicht / this.maxValue) * MAX_SCORE);
  }

  // Fuer die Anzeige: Anteil 0..1 der zuletzt gesungenen Note.
  get accuracy() {
    let hits = 0;
    let tries = 0;
    for (const s of this.state.values()) {
      hits += s.hits;
      tries += s.tries;
    }
    return tries > 0 ? hits / tries : 0;
  }
}
