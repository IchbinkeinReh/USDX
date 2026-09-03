// Zeichnet die Singansicht auf ein Canvas.
//
// Das Spiel nutzt OpenGL; im Browser ist Canvas 2D der passende Ersatz - fuer
// Notenbalken und Text braucht es kein WebGL, und 2D laeuft ueberall.
//
// Dargestellt wird je Stimme immer nur die AKTUELLE Zeile. Genau das macht
// das Spiel auch: Mehr passt nicht lesbar auf einen Bildschirm, und beim
// Singen schaut man ohnehin nur auf die naechsten Sekunden.
//
// Im Duett bekommt jede Stimme ihre eigene Bahn, uebereinander. Beide teilen
// sich dieselbe Zeitachse, damit man sieht, wann man dran ist.

import { noteProgress } from './song.js';

const BALKEN_RUND = 6;

// Wie lange vor dem Einsatz der Indikator erscheint, und in wie vielen
// Stufen. Stufen statt eines glatten Balkens, weil man daran ablesen kann,
// WANN genau es losgeht - ein gleitender Balken sagt nur "bald".
// Der Zeilenanzeiger ("lyric helper"), portiert aus SingDrawLyricHelper in
// src/base/UDraw.pas. Er faehrt von links auf den Anfang des Liedtextes zu
// und ist genau dann dort, wenn die erste Note faellig ist. Dabei pulsiert
// er im Takt.
//
// Die Werte stammen aus dem Spiel und sind in SCHLAEGEN gemessen, nicht in
// Sekunden - dadurch passt er sich dem Tempo des Liedes an:
//
//   BarMoveLimit = 40   ab so vielen Schlaegen Wartezeit bleibt er links
//                       stehen, statt sich unmerklich langsam zu bewegen
//   FirstNoteDelta > 8  erst ab so viel Vorlauf erscheint er ueberhaupt.
//                       Bei kurzen Pausen zwischen zwei Zeilen waere er nur
//                       ein Zucken und wuerde mehr stoeren als helfen.
export const HELFER_MIN_VORLAUF = 8;
export const HELFER_GRENZE = 40;

// Wo steht der Anzeiger gerade? null, wenn er nicht zu sehen ist.
// fortschritt 0 = ganz links, 1 = am Zeilenanfang angekommen.
export function lyricHelper(line, beat) {
  if (!line || !line.notes || line.notes.length === 0) return null;

  const ersterSchlag = line.notes[0].start;
  let vorlauf = ersterSchlag - line.startBeat;   // FirstNoteDelta
  let rest = ersterSchlag - beat;                // BarMoveDelta

  if (!(vorlauf > HELFER_MIN_VORLAUF)) return null;
  if (!(rest > 0)) return null;   // die Note ist da - der Anzeiger hat fertig

  // Das Pulsieren rechnet mit dem UNGEKUERZTEN Rest, so wie im Spiel: Es
  // haengt am Takt, nicht am Weg des Balkens.
  const alpha = 0.75 + Math.cos(rest / 2) * 0.25;

  if (rest > HELFER_GRENZE) rest = HELFER_GRENZE;
  if (vorlauf > HELFER_GRENZE) vorlauf = HELFER_GRENZE;

  let fortschritt = 1 - rest / vorlauf;
  // Im Spiel kann das nicht negativ werden, weil dort immer die schon
  // begonnene Zeile gilt. Hier wird frueher auf die naechste umgeschaltet,
  // damit der Text nicht stehenbleibt - dann liegt der Balken kurz vor
  // seinem Startpunkt. Begrenzen statt ihn aus dem Bild laufen zu lassen.
  if (fortschritt < 0) fortschritt = 0;
  if (fortschritt > 1) fortschritt = 1;

  return { fortschritt, alpha };
}

// Farben des Liedtextes.
const TEXT_GESUNGEN = '#8b93a4';   // liegt hinter uns
const TEXT_AKTIV    = '#ffd978';   // gerade zu hoeren
const TEXT_KOMMT    = '#e8e8ea';   // steht noch bevor

// Je Bahn eine Farbe, damit im Duett klar ist, wer wo singt.
const FARBEN = [
  { balken: '#4a5570', treffer: '#6ee7a8', stimme: '#7fd1ff' },
  { balken: '#6b4a70', treffer: '#e79ad8', stimme: '#ffb27f' },
];

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
  }

  // bahnen: [{ line, bars, anteile, name, score }]
  // beat:   aktueller Schlag, gilt fuer alle Bahnen
  // hintergrund: liegt Video oder Bild dahinter? Dann bleibt der Canvas
  //   durchsichtig, sonst verdeckte er beides.
  draw(bahnen, beat, hintergrund = false) {
    const { ctx, canvas } = this;
    const w = canvas.width, h = canvas.height;

    ctx.clearRect(0, 0, w, h);
    if (hintergrund) {
      // Nur abdunkeln, nicht zumalen. Ohne diesen Schleier verschwinden
      // Text und Noten in hellen Bildstellen - das Spiel macht es genauso.
      ctx.fillStyle = 'rgba(10, 12, 18, 0.45)';
    } else {
      ctx.fillStyle = '#11131a';
    }
    ctx.fillRect(0, 0, w, h);
    this.hintergrund = hintergrund;

    if (!bahnen || bahnen.length === 0) return;

    const hoehe = h / bahnen.length;
    bahnen.forEach((bahn, i) => {
      this.zeichneBahn(bahn, beat, i, 0, i * hoehe, w, hoehe,
                       bahnen.length > 1);
      if (i > 0) {
        ctx.strokeStyle = '#252b38';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, i * hoehe);
        ctx.lineTo(w, i * hoehe);
        ctx.stroke();
      }
    });
  }

  zeichneBahn(bahn, beat, index, ox, oy, w, h, mitNamen) {
    const ctx = this.ctx;
    const farbe = FARBEN[index % FARBEN.length];
    const line = bahn.line;

    ctx.save();
    ctx.translate(ox, oy);

    if (mitNamen && bahn.name) {
      ctx.font = '600 15px system-ui, sans-serif';
      ctx.textBaseline = 'top';
      if (this.hintergrund) {
        ctx.lineWidth = 3;
        ctx.strokeStyle = 'rgba(0,0,0,0.8)';
        ctx.lineJoin = 'round';
        ctx.strokeText(bahn.name, 12, 8);
      }
      ctx.fillStyle = farbe.stimme;
      ctx.fillText(bahn.name, 12, 8);
      // Kein Wert heisst "ohne Mikrofon". Eine 0 an dieser Stelle liesse es
      // aussehen, als saenge jemand daneben.
      ctx.textAlign = 'right';
      ctx.fillStyle = bahn.score === undefined ? '#5c6478' : '#ffd978';
      ctx.fillText(bahn.score === undefined ? 'nicht gewertet'
                                            : String(bahn.score), w - 12, 8);
      ctx.textAlign = 'left';
    }

    if (!line || line.notes.length === 0) {
      ctx.restore();
      return;
    }

    const letzte = line.notes[line.notes.length - 1];
    const von = line.notes[0].start;
    const bis = letzte.start + letzte.length;
    const spanne = Math.max(1, bis - von);

    // Tonhoehen der Zeile mittig legen, statt fest zu skalieren: Sonst
    // rutschen tiefe Lieder aus dem Bild.
    const toene = line.notes.map((n) => n.pitch);
    const mitte = (Math.min(...toene) + Math.max(...toene)) / 2;
    const umfang = Math.max(8, Math.max(...toene) - Math.min(...toene) + 4);

    // Notenhoehe aus dem Platz ableiten, nicht fest setzen: In der halben
    // Bahn eines Duetts waere ein fester Wert entweder winzig oder zu gross.
    const nutzbar = h * 0.55;
    const tonHoehe = Math.max(5, Math.min(14, nutzbar / umfang));

    const x = (b) => ((b - von) / spanne) * (w - 40) + 20;
    const y = (p) => h * 0.45 - (p - mitte) * tonHoehe;

    ctx.strokeStyle = this.hintergrund ? 'rgba(255,255,255,0.10)' : '#1e2230';
    ctx.lineWidth = 1;
    for (let p = -6; p <= 6; p += 2) {
      ctx.beginPath();
      ctx.moveTo(0, y(mitte + p));
      ctx.lineTo(w, y(mitte + p));
      ctx.stroke();
    }

    for (const note of line.notes) {
      const bx = x(note.start);
      const bw = Math.max(4, x(note.start + note.length) - bx);
      const by = y(note.pitch) - tonHoehe / 2;

      ctx.fillStyle = note.type === 'golden' ? '#e8b23a'
                    : note.type === 'freestyle' ? '#3a4152'
                    : farbe.balken;
      this.balken(bx, by, bw, tonHoehe, Math.min(BALKEN_RUND, tonHoehe / 2));

      const anteil = bahn.anteile ? bahn.anteile.get(note) : 0;
      if (anteil > 0) {
        ctx.fillStyle = note.type === 'golden' ? '#ffd978' : farbe.treffer;
        this.balken(bx, by, bw * Math.min(1, anteil), tonHoehe,
                    Math.min(BALKEN_RUND, tonHoehe / 2));
      }
    }

    // Was gesungen wurde, als Balken auf der erkannten Tonhoehe - wie im
    // Spiel (SingDrawPlayerLine). Es gibt sie nur dort, wo im Lied auch
    // Noten stehen; dafuer sorgt schon der Scorer, der nichts festhaelt,
    // solange keine wertbare Note laeuft.
    //
    // Eine Linie, die die Spielstelle anzeigt, gibt es bewusst nicht mehr:
    // Der letzte Balken steht ohnehin genau dort, und zwar mitsamt der
    // Auskunft, ob es gesessen hat.
    if (bahn.bars) {
      for (const bar of bahn.bars) {
        // Nur, was in diese Zeile faellt.
        if (bar.endBeat <= von || bar.startBeat >= bis) continue;

        const bx = x(bar.startBeat);
        const bw = Math.max(3, x(bar.endBeat) - bx);
        // Danebengesungen wird flacher gezeichnet - im Spiel 65 Prozent.
        // Das unterscheidet Treffer und Fehlgriff ohne zweite Farbe.
        const dick = tonHoehe * (bar.hit ? 1 : 0.65);
        const by = y(bar.tone - 60) - dick / 2;

        ctx.fillStyle = bar.hit ? farbe.treffer : farbe.stimme;
        ctx.globalAlpha = bar.hit ? 1 : 0.7;
        this.balken(bx, by, bw, dick, Math.min(BALKEN_RUND, dick / 2));
        ctx.globalAlpha = 1;
      }
    }

    // Der Anzeiger faehrt auf den Textanfang zu - deshalb erst den Text
    // zeichnen und dessen linken Rand als Ziel nehmen.
    const textLinks = this.text(line, beat, w, h);
    this.helfer(line, beat, textLinks, w, h);
    ctx.restore();
  }

  balken(x, y, w, h, r) {
    const ctx = this.ctx;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
    ctx.fill();
  }

  // Der Liedtext.
  //
  // Die gerade zu hoerende Silbe wird nicht nur hervorgehoben, sondern
  // WAEHREND des Singens von links nach rechts eingefaerbt - derselbe Effekt
  // wie lfxSlide in ULyrics.pas: Die Silbe wird bei ihrem Fortschritt geteilt,
  // links "schon gesungen", rechts "kommt noch". Ohne das springt die Farbe
  // silbenweise und man sieht nicht, wo im Wort man gerade ist.
  text(line, beat, w, h) {
    const ctx = this.ctx;
    const groesse = Math.max(15, Math.min(26, h * 0.09));
    ctx.font = `600 ${groesse}px system-ui, sans-serif`;
    ctx.textBaseline = 'alphabetic';

    const breiten = line.notes.map((n) => ctx.measureText(n.text).width);
    const gesamt = breiten.reduce((a, b) => a + b, 0);
    const links = (w - gesamt) / 2;
    let cx = links;
    const cy = h - groesse * 0.6;

    // Auf bewegtem Bild wandert staendig Helligkeit unter den Text. Ein
    // Rand macht ihn unabhaengig davon lesbar; ohne ihn verschwinden einzelne
    // Silben genau dann, wenn man sie braucht.
    const mitRand = this.hintergrund;
    if (mitRand) {
      ctx.lineWidth = Math.max(3, groesse * 0.16);
      ctx.strokeStyle = 'rgba(0, 0, 0, 0.85)';
      ctx.lineJoin = 'round';
    }

    line.notes.forEach((note, i) => {
      const breite = breiten[i];
      const aktiv = beat >= note.start && beat < note.start + note.length;

      if (mitRand) ctx.strokeText(note.text, cx, cy);

      if (aktiv) {
        // Erst ganz in der Farbe "kommt noch", dann den bereits gesungenen
        // Teil beschnitten darueber. Zwei Zeichnungen, ein Beschnitt.
        ctx.fillStyle = TEXT_KOMMT;
        ctx.fillText(note.text, cx, cy);

        const anteil = noteProgress(note, beat);
        if (anteil > 0) {
          ctx.save();
          ctx.beginPath();
          ctx.rect(cx, cy - groesse * 1.2, breite * anteil, groesse * 1.6);
          ctx.clip();
          ctx.fillStyle = TEXT_AKTIV;
          ctx.fillText(note.text, cx, cy);
          ctx.restore();
        }
      } else {
        ctx.fillStyle = beat >= note.start ? TEXT_GESUNGEN : TEXT_KOMMT;
        ctx.fillText(note.text, cx, cy);
      }

      cx += breite;
    });

    return links;
  }

  // Zeichnet den Zeilenanzeiger.
  //
  // textLinks ist der linke Rand des Liedtextes - dorthin faehrt er. Die
  // Groesse ist an die Bahn angepasst; im Spiel sind es feste 50x30 in einem
  // 800x600-Raster, was hier nichts hiesse.
  helfer(line, beat, textLinks, w, h) {
    const stand = lyricHelper(line, beat);
    if (!stand) return;

    const ctx = this.ctx;
    const breite = Math.max(24, Math.min(50, w * 0.04));
    const hoehe = Math.max(6, h * 0.026);
    const y = h - Math.max(15, Math.min(26, h * 0.09)) * 1.9;

    // Von links bis kurz vor den Text. Ist die Zeile so lang, dass davor
    // kein Platz bleibt, faengt er entsprechend weiter links an - im Spiel
    // steht dafuer dieselbe Fallunterscheidung.
    const ziel = textLinks - breite - 6;
    const start = Math.min(8, ziel);
    const x = start + stand.fortschritt * (ziel - start);

    ctx.save();
    ctx.globalAlpha = stand.alpha;
    ctx.fillStyle = '#7fd1ff';
    ctx.beginPath();
    ctx.roundRect(x, y, breite, hoehe, hoehe / 2);
    ctx.fill();
    ctx.restore();
  }
}
