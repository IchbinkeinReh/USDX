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

import { countsForScore, noteFactor, NOTE_RAP, NOTE_RAP_GOLDEN } from './song.js';

export const MAX_SCORE = 10000;

// Vom Gesamtwert sind 1000 fuer den Zeilenbonus reserviert; die Noten
// koennen hoechstens die restlichen 9000 bringen. Beides steht so in
// UNote.pas (MAX_SONG_SCORE, MAX_SONG_LINE_BONUS).
export const MAX_LINE_BONUS = 1000;
export const MAX_NOTE_SCORE = MAX_SCORE - MAX_LINE_BONUS;

// Hoechste Bewertungsstufe einer Zeile (MAX_LINE_RATING in
// UScreenSingController.pas). Der Wert 0..8 waehlt den Text aus.
export const MAX_LINE_RATING = 8;

// Bezeichnungen aus game/languages/German.ini. Stufe 1 hat im Spiel
// denselben Text wie Stufe 0 - das ist dort kein Versehen, sondern Absicht
// (LineBonusText[1] := LineBonusText[0] in UThemes.pas).
export const ZEILEN_TEXTE = [
  'Grausam!', 'Grausam!', 'Mies!', 'Schlecht!', 'O.K.!',
  'Gut!', 'Toll!', 'Cool!', 'Perfekt!',
];

// Wie gut eine Zeile war, aus dem erreichten Anteil.
//
// Aus UScreenSingController.pas: Rating := Round(LinePerfection *
// MAX_LINE_RATING).
export function zeilenBewertung(guete) {
  const g = Math.max(0, Math.min(1, Number.isFinite(guete) ? guete : 0));
  const stufe = Math.round(g * MAX_LINE_RATING);
  return { stufe, name: ZEILEN_TEXTE[stufe] };
}

// Schwierigkeitsstufen wie im Spiel (IDifficulty in UIni.pas).
export const LEICHT = 0;
export const MITTEL = 1;
export const SCHWER = 2;

// Wie viele Halbtoene daneben noch als Treffer zaehlen.
//
// Im Spiel: Range := 2 - Ini.Difficulty (UNote.pas). Leicht laesst also zwei
// Halbtoene zu, Mittel einen, Schwer gar keinen.
export function toleranz(schwierigkeit) {
  const s = Math.max(LEICHT, Math.min(SCHWER, schwierigkeit | 0));
  return 2 - s;
}

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
  // Leicht ist die Voreinstellung: Mit Raummikrofon und laufender Musik ist
  // der Halbton auf den Punkt kaum zu treffen, und wer nichts trifft, hoert
  // auf zu singen.
  constructor(song, trackIndex = 0, schwierigkeit = LEICHT) {
    this.song = song;
    this.trackIndex = trackIndex;
    this.schwierigkeit = schwierigkeit;
    this.toleranz = toleranz(schwierigkeit);
    this.track = song.track ? song.track(trackIndex) : song;
    this.maxValue = this.track.maxNoteValue;
    // Zeilen mit Notenwert - nur die zaehlen fuer den Bonus. Eine Zeile ohne
    // wertbare Noten wird im Spiel uebersprungen (Line.ScoreValue <= 0), und
    // sie darf den Bonus je Zeile auch nicht verwaessern.
    this.zeilen = this.track.lines.map((z) => ({
      zeile: z,
      wert: z.notes.filter((n) => countsForScore(n.type))
                   .reduce((sum, n) => sum + n.length * noteFactor(n.type), 0),
      erledigt: false,
    })).filter((e) => e.wert > 0);
    // Bonus je Zeile, gleich viel fuer jede - egal wie lang sie ist.
    this.bonusJeZeile = this.zeilen.length > 0
      ? MAX_LINE_BONUS / this.zeilen.length : 0;
    this.zeilenBonus = 0;
    this.letzteWertung = 0;     // Notenpunkte beim Ende der letzten Zeile
    // Die zuletzt abgeschlossene Zeile, fuer die Einblendung.
    this.letzteZeile = null;
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
    // ZUERST die Zeilenenden pruefen, nicht erst nach der Abfrage unten:
    // Eine Zeile endet mit ihrer letzten Note, danach ist Pause - und in
    // einer Pause steigt diese Methode gleich wieder aus. Der Bonus waere
    // sonst nie gutgeschrieben worden.
    this.pruefeZeilenende(seconds);

    const note = this.noteAt(seconds);
    if (!note || !countsForScore(note.type)) return null;

    let s = this.state.get(note);
    if (!s) {
      s = { hits: 0, tries: 0 };
      this.state.set(note, s);
    }
    s.tries++;
    const treffer = this.trifft(sungMidi, note);
    if (treffer) s.hits++;

    this.merkeBalken(seconds, sungMidi, note, treffer);
    return treffer;
  }

  // Schliesst Zeilen ab, deren letzte Note vorbei ist, und schreibt den
  // Zeilenbonus gut.
  //
  // Aus UScreenSingController.pas:
  //
  //   MaxLineScore   = 9000 * (Zeilenwert / Gesamtwert)
  //   LineScore      = erreichte Punkte seit der letzten Zeile
  //   LinePerfection = LineScore / (MaxLineScore - 2), begrenzt auf 0..1
  //   ScoreLine     += LineBonus * LinePerfection
  //
  // Die zwei Punkte Nachlass sind im Original ausdruecklich als kleine
  // Zugabe gedacht, damit man fuer die volle Stufe nicht ganz perfekt sein
  // muss - deshalb hier ebenso.
  pruefeZeilenende(seconds) {
    const beat = this.song.timeToBeat(seconds);
    for (const e of this.zeilen) {
      if (e.erledigt) continue;
      const letzte = e.zeile.notes[e.zeile.notes.length - 1];
      if (beat < letzte.start + letzte.length) continue;

      e.erledigt = true;
      const maxZeile = (e.wert / this.maxValue) * MAX_NOTE_SCORE;
      const erreicht = this.notenPunkte - this.letzteWertung;
      let guete = maxZeile <= 2 ? 1 : erreicht / (maxZeile - 2);
      if (guete < 0) guete = 0;
      if (guete > 1) guete = 1;

      this.zeilenBonus += this.bonusJeZeile * guete;
      this.letzteWertung = this.notenPunkte;
      this.letzteZeile = {
        guete,
        ...zeilenBewertung(guete),
        zeit: seconds,
      };
    }
  }

  // Die Trefferpruefung des Spiels (UNote.pas):
  //
  //   Abs(Note.Tone - Sound.Tone) <= Range
  //     or Note.NoteType = ntRap or ntRapGolden
  //
  // Der gesungene Ton ist dabei schon in die Oktave der Zielnote geholt -
  // ohne das koennte niemand eine Oktave tiefer mitsingen. Rap-Noten treffen
  // immer: Dort geht es um den Rhythmus, nicht um die Tonhoehe.
  trifft(sungMidi, note) {
    if (note.type === NOTE_RAP || note.type === NOTE_RAP_GOLDEN) return true;
    if (!(sungMidi >= 0)) return false;
    const ziel = note.pitch + 60;
    return Math.abs(ziel - inOktave(sungMidi, ziel)) <= this.toleranz;
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

  // Punkte aus den Noten allein, hoechstens MAX_NOTE_SCORE.
  get notenPunkte() {
    if (!(this.maxValue > 0)) return 0;
    let erreicht = 0;
    for (const [note, s] of this.state) {
      if (s.tries === 0) continue;
      // Anteil der getroffenen Bloecke, gewichtet wie die Note selbst.
      erreicht += (s.hits / s.tries) * note.length * noteFactor(note.type);
    }
    return (erreicht / this.maxValue) * MAX_NOTE_SCORE;
  }

  // Gesamtpunktzahl: Noten plus Zeilenbonus, wie im Spiel
  // (Score + ScoreGolden + ScoreLine).
  get score() {
    return Math.round(this.notenPunkte + this.zeilenBonus);
  }

  // Punkte getrennt nach gewoehnlichen Noten, goldenen Noten und
  // Zeilenbonus - so schluesselt es auch die Ergebnisseite des Spiels auf.
  teilwertung() {
    let normal = 0;
    let golden = 0;
    if (this.maxValue > 0) {
      for (const [note, s] of this.state) {
        if (s.tries === 0) continue;
        const wert = (s.hits / s.tries) * note.length * noteFactor(note.type)
                     / this.maxValue * MAX_NOTE_SCORE;
        if (noteFactor(note.type) > 1) golden += wert;
        else normal += wert;
      }
    }
    return {
      normal: Math.round(normal),
      golden: Math.round(golden),
      bonus: Math.round(this.zeilenBonus),
    };
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
