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

// Holt den gesungenen Ton in die Oktave der Zielnote.
//
// Genau wie in UNote.pas (NewNote): Solange der Abstand groesser als eine
// halbe Oktave ist, um zwoelf verschieben. Ohne das zeichnete man den Balken
// meterweit ueber oder unter der Note, obwohl richtig gesungen wurde - wer
// tief singt, traefe optisch nie.
export function inOktave(sungMidi, zielMidi) {
  let ton = sungMidi;
  while (ton - zielMidi > 6) ton -= 12;
  while (ton - zielMidi < -6) ton += 12;
  return ton;
}

export class Scorer {
  // trackIndex waehlt die Stimme. Beim Solo gibt es nur die 0, beim Duett
  // bekommt jeder Saenger seine eigene Wertung gegen seine eigene Spur.
  constructor(song, trackIndex = 0) {
    this.song = song;
    this.trackIndex = trackIndex;
    this.track = song.track ? song.track(trackIndex) : song;
    this.maxValue = this.track.maxNoteValue;
    // Je Note: wie viele Treffer und wie viele Versuche.
    this.state = new Map();
    // Was tatsaechlich gesungen wurde, als Balken zum Zeichnen:
    // [{ startBeat, endBeat, tone, hit }]. tone ist eine MIDI-Nummer.
    this.bars = [];
  }

  get name() {
    return this.track && this.track.name ? this.track.name : '';
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

    this.merkeBalken(seconds, sungMidi, note, treffer);
    return treffer;
  }

  // Haelt fest, was gesungen wurde - aber NUR dort, wo im Lied auch eine
  // Note steht. Aufgerufen wird das nur aus feed(), und das steigt vorher
  // aus, wenn gerade keine wertbare Note laeuft; in USDX ist das die
  // Bedingung "ToneValid and NoteAvailable".
  merkeBalken(seconds, sungMidi, note, treffer) {
    if (!(sungMidi >= 0)) return;   // nichts erkannt - kein Balken

    const ziel = note.pitch + 60;
    // Bei einem Treffer rastet der Balken auf der Zielnote ein. Sonst saehe
    // ein Treffer aus wie ein knapper Fehlschlag, nur weil die Messung ein
    // Achtel daneben lag - USDX macht dasselbe (ActualTone := Tone).
    const ton = treffer ? ziel : Math.round(inOktave(sungMidi, ziel));

    // In ganzen Schlaegen, wie im Spiel. Sonst entstuenden bei jedem Bild
    // Splitter statt Balken.
    const schlag = Math.floor(this.song.timeToBeat(seconds));
    const letzter = this.bars[this.bars.length - 1];

    // Nahtlos anschliessend und gleicher Ton? Dann verlaengern statt einen
    // zweiten Balken danebenzusetzen.
    if (letzter && letzter.tone === ton && letzter.hit === treffer &&
        letzter.endBeat === schlag) {
      letzter.endBeat = schlag + 1;
      return;
    }
    // Derselbe Schlag noch einmal - nichts zu tun.
    if (letzter && letzter.endBeat > schlag && letzter.tone === ton) return;

    this.bars.push({
      startBeat: schlag, endBeat: schlag + 1, tone: ton, hit: treffer,
    });
  }

  // Welche Note ist zu diesem Zeitpunkt zu singen? null in den Pausen.
  noteAt(seconds) {
    const beat = this.song.timeToBeat(seconds);
    for (const note of this.track.notes) {
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
