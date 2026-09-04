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

// Wo der Anzeiger faehrt: von links bis kurz vor den Textanfang.
//
// ALLE Masse sind Anteile der Breite, keine festen Punkte. Das ist kein
// Schoenheitsgrund: Der Canvas ist mit devicePixelRatio vergroessert, und
// alles andere hier rechnet ebenfalls in Canvas-Punkten relativ zur Groesse.
// Eine feste Zahl schrumpft dagegen auf einem Handy mit dreifacher Aufloesung
// auf ein Drittel - der Balken war 9 Punkte hoch und damit 3 CSS-Punkte, also
// ein Haarstrich, den man schlicht uebersieht.
//
// Der Mindestweg ist der zweite Grund fuer diese Funktion: Ohne ihn landete
// der Balken bei breiten, mittig gesetzten Zeilen links AUSSERHALB des
// Bildes. Ziel bleibt der Textanfang, nur nie naeher als dieser Weg.
export function helferBahn(textLinks, w) {
  // In CSS-Punkten, siehe passeGroesseAn. Nach unten begrenzt, damit der
  // Balken auf schmalen Bildschirmen nicht zum Strich wird.
  const breite = Math.max(30, Math.min(90, w * 0.055));
  const start = Math.max(8, w * 0.012);
  const ziel = Math.max(start + w * 0.18, textLinks - breite - 8);
  return { start, ziel, breite };
}

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
// Die naechste Zeile ist weiss, nicht grau: Man liest sie im Voraus, um
// vorbereitet zu sein - dafuer muss sie gut lesbar sein. Abgesetzt wird sie
// ueber die kleinere Schrift, nicht ueber blasse Farbe.
const TEXT_VORSCHAU = '#ffffff';

// Wie lange die Bewertung einer Zeile stehen bleibt.
export const ZEILENLOB_SEK = 1.6;

// Je Bahn eine Farbe, damit im Duett klar ist, wer wo singt.
const FARBEN = [
  { balken: '#4a5570', treffer: '#6ee7a8', stimme: '#7fd1ff' },
  { balken: '#6b4a70', treffer: '#e79ad8', stimme: '#ffb27f' },
];

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.w = 0;
    this.h = 0;
  }

  // Setzt die Groesse und rechnet den Kontext auf CSS-Punkte um.
  //
  // Ohne das bedeuten alle festen Masse hier etwas anderes, je nach Geraet:
  // Der Canvas wird mit devicePixelRatio vergroessert, damit das Bild scharf
  // ist - eine Schriftgroesse von 24 waere auf einem Handy mit dreifacher
  // Aufloesung dann 8 CSS-Punkte, also unlesbar. Mit dieser Umrechnung heisst
  // 24 ueberall 24.
  passeGroesseAn(cssBreite, cssHoehe, dpr = 1) {
    if (!(cssBreite > 0) || !(cssHoehe > 0)) return;
    this.canvas.width = Math.round(cssBreite * dpr);
    this.canvas.height = Math.round(cssHoehe * dpr);
    this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.w = cssBreite;
    this.h = cssHoehe;
  }

  // bahnen: [{ line, nextLine, bars, name, score }]
  // beat:   aktueller Schlag, gilt fuer alle Bahnen
  // hintergrund: liegt Video oder Bild dahinter? Dann bleibt der Canvas
  //   durchsichtig, sonst verdeckte er beides.
  // fortschritt: { zeit, dauer, abschnitte } - wo im Lied wir stehen und
  // wann ueberhaupt gesungen wird.
  // duett: beim Duett hat jede Stimme ihren eigenen Text; sonst singen alle
  //   denselben und er wird nur EINMAL gezeigt.
  draw(bahnen, beat, hintergrund = false, fortschritt = null, duett = false) {
    const { ctx, canvas } = this;
    // Ohne passeGroesseAn auf die rohen Canvas-Masse zurueckfallen - so
    // laesst sich das Zeichnen auch ohne Browser durchrechnen.
    const w = this.w || canvas.width;
    const h = this.h || canvas.height;

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

    // Unten ein schmaler Streifen fuer den Fortschritt, der Rest fuer die
    // Bahnen.
    const leisteH = fortschritt ? Math.max(3, Math.min(7, h * 0.015)) : 0;
    const bahnenH = h - leisteH;

    // Beim Duett bekommt jede Stimme ihren Text: der oberen ueber ihre
    // Noten, der unteren darunter. So liegen die Texte aussen und die
    // Notenflaechen in der Mitte beieinander - dieselbe Aufteilung wie im
    // Spiel, wo die Textleisten oben und unten sitzen.
    //
    // Singen dagegen alle dieselbe Spur, waere zweimal derselbe Text nur
    // Platzverschwendung. Dann bleiben die Bahnen textfrei und der Text
    // steht einmal unten.
    // Wird niemand gewertet - alle ohne Mikrofon -, sind Notenlinien und
    // Balken ohne Aussage: Es kann nichts getroffen und nichts verfehlt
    // werden. Dann bleibt die Flaeche frei, und es geht nur um Text und
    // Video. Sobald AUCH NUR EINER gewertet wird, sind sie wieder da.
    const wirdGewertet = bahnen.some((b) => b.score !== undefined);
    this.ohneNoten = !wirdGewertet;

    const gemeinsam = !duett;
    // Dieselben Masse zum Rechnen wie zum Zeichnen - vorher wurde die
    // Bandhoehe hier bestimmt und beim Zeichnen aus ihr zurueckgerechnet,
    // was eine andere Schriftgroesse ergab.
    const gemeinsamMasse = this.bandMasse(bahnenH);
    const bandH = gemeinsam ? gemeinsamMasse.hoehe : 0;
    const laneH = (bahnenH - bandH) / bahnen.length;

    bahnen.forEach((bahn, i) => {
      const lage = gemeinsam ? null : (i === 0 ? 'oben' : 'unten');
      this.zeichneBahn(bahn, beat, i, 0, i * laneH, w, laneH,
                       bahnen.length > 1, lage);
      if (i > 0) {
        ctx.strokeStyle = '#252b38';
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(0, i * laneH);
        ctx.lineTo(w, i * laneH);
        ctx.stroke();
      }
    });

    if (gemeinsam && bahnen[0]) {
      this.textBand(bahnen[0], beat, w, bahnenH - bandH, bandH,
                    gemeinsamMasse.schrift, gemeinsamMasse.zeilenH,
                    gemeinsamMasse.helferH);
    }

    if (fortschritt) this.leiste(fortschritt, 0, bahnenH, w, leisteH);
  }

  // Der Fortschrittsbalken am unteren Rand.
  //
  // Nachgebaut nach DrawInfoLyricBar (UScreenSingView.pas): eine Leiste ueber
  // die ganze Laenge des Liedes, darin je Zeile ein Kaestchen von der ersten
  // Note bis zum Ende der letzten. Man sieht damit auf einen Blick, wann
  // gesungen wird und wann Pause ist - und wie lange es noch dauert.
  leiste({ zeit, dauer, abschnitte }, x, y, w, h) {
    const ctx = this.ctx;
    if (!(dauer > 0)) return;

    ctx.fillStyle = 'rgba(8, 10, 15, 0.85)';
    ctx.fillRect(x, y, w, h);

    // Die Singabschnitte.
    ctx.fillStyle = 'rgba(127, 209, 255, 0.55)';
    for (const a of abschnitte || []) {
      const ax = x + (a.von / dauer) * w;
      const aw = Math.max(1, ((a.bis - a.von) / dauer) * w);
      ctx.fillRect(ax, y + 1, aw, h - 2);
    }

    // Das bereits Gesungene abdunkeln - so sieht man den Fortschritt auch
    // dann, wenn die Marke gerade in einer Pause steht.
    const px = x + Math.max(0, Math.min(1, zeit / dauer)) * w;
    ctx.fillStyle = 'rgba(0, 0, 0, 0.45)';
    ctx.fillRect(x, y, px - x, h);

    // Die Marke selbst.
    ctx.fillStyle = '#ffd978';
    ctx.fillRect(px - 1, y, 2, h);
  }

  // Wie hoch das Textband bei dieser Bahnenhoehe wird. Getrennt gerechnet,
  // weil draw() den Platz kennen muss, bevor die Bahnen gezeichnet werden.
  bandMasse(h) {
    const schrift = Math.max(14, Math.min(24, h * 0.075));
    const zeilenH = schrift * 1.45;
    const helferH = Math.max(8, schrift * 0.42);
    return { schrift, zeilenH, helferH,
             hoehe: schrift * 0.35 + zeilenH * 2 + schrift * 0.35 };
  }

  bandHoehe(h) { return this.bandMasse(h).hoehe; }

  zeichneBahn(bahn, beat, index, ox, oy, w, h, mitNamen, textLage = 'unten') {
    const ctx = this.ctx;
    const farbe = FARBEN[index % FARBEN.length];
    const line = bahn.line;

    ctx.save();
    ctx.translate(ox, oy);

    // Ein eigenes Band fuer Anzeiger und zwei Textzeilen. Wo es liegt,
    // entscheidet textLage; die Noten bekommen den Rest - sonst ueberdeckten
    // sich beide.
    const { schrift, zeilenH, helferH, hoehe: bandH } = this.bandMasse(h);
    const hatBand = textLage === 'oben' || textLage === 'unten';
    const bandY = textLage === 'oben' ? 0 : h - bandH;
    // Bei Text oben faengt die Notenflaeche darunter an.
    const notenY = textLage === 'oben' ? bandH : 0;
    const notenH = hatBand ? h - bandH : h;

    // Punktzahl und Name stehen in der Bahn, nicht mehr in der Kopfleiste -
    // dort nahmen sie Platz weg, den die Noten brauchen. Die Punktzahl wird
    // immer gezeigt, der Name nur, wenn es mehrere Bahnen gibt.
    const kopfY = textLage === 'oben' ? bandH + 6 : 8;
    if (bahn.score !== undefined || bahn.name) {
      ctx.font = '600 15px system-ui, sans-serif';
      ctx.textBaseline = 'top';
      if (mitNamen && bahn.name) {
        if (this.hintergrund) {
          ctx.lineWidth = 3;
          ctx.strokeStyle = 'rgba(0,0,0,0.8)';
          ctx.lineJoin = 'round';
          ctx.strokeText(bahn.name, 12, kopfY);
        }
        ctx.fillStyle = farbe.stimme;
        ctx.fillText(bahn.name, 12, kopfY);
      }
      // Kein Wert heisst "ohne Mikrofon". Eine 0 an dieser Stelle liesse es
      // aussehen, als saenge jemand daneben.
      ctx.textAlign = 'right';
      if (this.hintergrund) {
        ctx.lineWidth = 3;
        ctx.strokeStyle = 'rgba(0,0,0,0.8)';
        ctx.lineJoin = 'round';
        ctx.strokeText(bahn.score === undefined ? 'nicht gewertet'
                                                : String(bahn.score), w - 12, kopfY);
      }
      ctx.fillStyle = bahn.score === undefined ? '#5c6478' : '#ffd978';
      ctx.fillText(bahn.score === undefined ? 'nicht gewertet'
                                            : String(bahn.score), w - 12, kopfY);
      ctx.textAlign = 'left';
    }

    if (!line || line.notes.length === 0) {
      if (hatBand)
        this.textBand(bahn, beat, w, bandY, bandH, schrift, zeilenH, helferH);
      ctx.restore();
      return;
    }

    if (this.ohneNoten) {
      if (hatBand)
        this.textBand(bahn, beat, w, bandY, bandH, schrift, zeilenH, helferH);
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
    const nutzbar = notenH * 0.62;
    const tonHoehe = Math.max(5, Math.min(14, nutzbar / umfang));

    const x = (b) => ((b - von) / spanne) * (w - 40) + 20;
    // Mitte des Notenbereichs, nicht der ganzen Bahn - der Rest gehoert dem
    // Textband, das je nach Lage darueber oder darunter sitzt.
    const y = (p) => notenY + notenH * 0.55 - (p - mitte) * tonHoehe;

    ctx.strokeStyle = this.hintergrund ? 'rgba(255,255,255,0.10)' : '#1e2230';
    ctx.lineWidth = 1;
    for (let p = -6; p <= 6; p += 2) {
      const ly = y(mitte + p);
      if (ly < notenY || ly > notenY + notenH) continue;
      ctx.beginPath();
      ctx.moveTo(0, ly);
      ctx.lineTo(w, ly);
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

      // Frueher wurde die Note anteilig eingefaerbt, und zwar mit dem
      // Verhaeltnis Treffer zu Versuchen. Das ist ein VERHAELTNIS und kann
      // sinken: Wer erst trifft und dann danebenliegt, sah den Balken
      // schrumpfen, obwohl er weitersang. Was tatsaechlich gesungen wurde,
      // zeigen die Balken weiter unten - und die wachsen nur.
    }

    this.zeilenLob(bahn, w, notenY, notenH);

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

    if (hatBand)
      this.textBand(bahn, beat, w, bandY, bandH, schrift, zeilenH, helferH);
    ctx.restore();
  }

  // Das Textband: abgedunkelter Streifen, darin der Anzeiger und zwei
  // Zeilen - die aktuelle und die naechste.
  //
  // Abgedunkelt wird immer, nicht nur ueber Video: Auch die Notenflaeche
  // darunter ist unruhig genug, dass Text darauf schlecht zu lesen ist.
  textBand(bahn, beat, w, bandY, bandH, schrift, zeilenH, helferH) {
    const ctx = this.ctx;

    // Nach oben auslaufend, damit es keine harte Kante quer durchs Bild gibt.
    const verlauf = ctx.createLinearGradient(0, bandY - schrift, 0, bandY + 8);
    verlauf.addColorStop(0, 'rgba(8, 10, 15, 0)');
    verlauf.addColorStop(1, 'rgba(8, 10, 15, 0.72)');
    ctx.fillStyle = verlauf;
    ctx.fillRect(0, bandY - schrift, w, schrift + 8);
    ctx.fillStyle = 'rgba(8, 10, 15, 0.72)';
    ctx.fillRect(0, bandY + 8, w, bandH - 8);

    if (!bahn.line) return;

    const y0 = bandY + schrift * 0.35;
    const grundlinie = y0 + zeilenH * 0.75;
    const masse = this.zeilenMasse(bahn.line, w, schrift);

    // Der Anzeiger sitzt AUF der Hoehe der ersten Textzeile, nicht darueber:
    // Er zeigt auf den Punkt, an dem der Text anfaengt, und das liest sich
    // nur, wenn beide auf einer Linie liegen.
    //
    // Gezeichnet wird er VOR dem Text. Bei einer Zeile, die fast die ganze
    // Breite fuellt, bleibt links kein Platz und beide ueberlappen - dann
    // steht der Text obendrauf und bleibt lesbar.
    this.helfer(bahn.line, beat, masse.links,
                grundlinie - schrift * 0.32 - helferH / 2, helferH, w);

    this.text(bahn.line, beat, w, grundlinie, schrift, true, masse);
    if (bahn.nextLine)
      this.text(bahn.nextLine, -Infinity, w, y0 + zeilenH * 1.75,
                schrift * 0.85, false);
  }

  balken(x, y, w, h, r) {
    const ctx = this.ctx;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
    ctx.fill();
  }

  // Wo steht die Zeile und wie breit ist sie? Getrennt vom Zeichnen, weil
  // der Anzeiger den linken Rand braucht, aber VOR dem Text gezeichnet wird.
  zeilenMasse(line, w, groesse) {
    const ctx = this.ctx;
    ctx.font = `600 ${groesse}px system-ui, sans-serif`;
    const breiten = line.notes.map((n) => ctx.measureText(n.text).width);
    const gesamt = breiten.reduce((a, b) => a + b, 0);
    // Passt die Zeile nicht, wird sie gestaucht statt abgeschnitten - eine
    // halbe Silbe am Rand hilft niemandem.
    const skal = gesamt > w - 24 ? (w - 24) / gesamt : 1;
    return { breiten, gesamt, skal, links: (w - gesamt * skal) / 2 };
  }

  // Eine Zeile Liedtext. Gibt den linken Rand zurueck - dorthin faehrt der
  // Anzeiger.
  //
  // Die gerade zu hoerende Silbe wird nicht nur hervorgehoben, sondern
  // WAEHREND des Singens von links nach rechts eingefaerbt - derselbe Effekt
  // wie lfxSlide in ULyrics.pas: Die Silbe wird bei ihrem Fortschritt geteilt,
  // links "schon gesungen", rechts "kommt noch". Ohne das springt die Farbe
  // silbenweise und man sieht nicht, wo im Wort man gerade ist.
  //
  // aktiv=false zeichnet die Vorschauzeile: gedaempft, ohne Einfaerbung.
  text(line, beat, w, cy, groesse, aktiv, masse) {
    const ctx = this.ctx;
    ctx.font = `600 ${groesse}px system-ui, sans-serif`;
    ctx.textBaseline = 'alphabetic';

    const { breiten, skal, links } = masse || this.zeilenMasse(line, w, groesse);
    let cx = links;

    ctx.save();
    if (skal < 1) {
      ctx.translate(links, 0);
      ctx.scale(skal, 1);
      cx = 0;
    }

    if (!aktiv) {
      // Vorschau: eine Farbe, kein Fortschritt. Sie ist noch nicht dran.
      ctx.fillStyle = TEXT_VORSCHAU;
      line.notes.forEach((note, i) => {
        ctx.fillText(note.text, cx, cy);
        cx += breiten[i];
      });
      ctx.restore();
      return links;
    }

    line.notes.forEach((note, i) => {
      const breite = breiten[i];
      const gerade = beat >= note.start && beat < note.start + note.length;

      if (gerade) {
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

    ctx.restore();
    return links;
  }

  // Die Bewertung der eben beendeten Zeile, kurz eingeblendet - im Spiel ist
  // das das Popup, das nach jeder Zeile aufsteigt.
  //
  // Sie verblasst und steigt dabei ein Stueck: Bliebe sie einfach stehen und
  // verschwaende dann, wuesste man nicht, ob sie zur letzten oder zur
  // naechsten Zeile gehoert.
  zeilenLob(bahn, w, notenY, notenH) {
    const lob = bahn.zeilenLob;
    if (!lob || !(lob.alter >= 0) || lob.alter > ZEILENLOB_SEK) return;

    const ctx = this.ctx;
    const t = lob.alter / ZEILENLOB_SEK;
    const groesse = Math.max(18, Math.min(34, notenH * 0.18));
    const y = notenY + notenH * 0.32 - t * notenH * 0.12;

    ctx.save();
    // Erst am Ende ausblenden, sonst ist sie zu kurz zu lesen.
    ctx.globalAlpha = t < 0.7 ? 1 : (1 - t) / 0.3;
    ctx.font = `700 ${groesse}px system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.lineWidth = Math.max(3, groesse * 0.18);
    ctx.strokeStyle = 'rgba(0,0,0,0.85)';
    ctx.lineJoin = 'round';
    ctx.strokeText(lob.name, w / 2, y);
    // Farbe nach Stufe: von blass bei "Grausam!" bis golden bei "Perfekt!".
    ctx.fillStyle = lob.stufe >= 7 ? '#ffd978'
                  : lob.stufe >= 4 ? '#6ee7a8'
                  : '#c3c9d6';
    ctx.fillText(lob.name, w / 2, y);
    ctx.restore();
    ctx.textAlign = 'left';
  }

  // Zeichnet den Zeilenanzeiger.
  //
  // Er bekommt eine EIGENE Reihe ueber dem Text, statt neben ihm zu fahren.
  // Im Spiel faehrt er bis kurz vor den Textanfang - bei mittig gesetztem,
  // breitem Text bleibt links davon aber kein Platz, und dann landete er
  // ausserhalb des Bildes. Genau deshalb war er nicht zu sehen.
  //
  // Ziel bleibt der Textanfang, nur eben mit einem Mindestweg: So zeigt er
  // weiter auf die Stelle, an der es losgeht, und ist trotzdem immer sichtbar.
  helfer(line, beat, textLinks, y, hoehe, w) {
    const stand = lyricHelper(line, beat);
    if (!stand) return;

    const ctx = this.ctx;
    const { start, ziel, breite } = helferBahn(textLinks, w);
    const x = start + stand.fortschritt * (ziel - start);

    ctx.save();
    ctx.globalAlpha = stand.alpha;
    // Dunkler Saum darunter: Der Balken liegt auf dem abgedunkelten Band,
    // aber je nach Video ist das nicht dunkel genug.
    ctx.fillStyle = 'rgba(0,0,0,0.55)';
    ctx.beginPath();
    ctx.roundRect(x - 2, y - 2, breite + 4, hoehe + 4, (hoehe + 4) / 2);
    ctx.fill();
    ctx.fillStyle = '#7fd1ff';
    ctx.beginPath();
    ctx.roundRect(x, y, breite, hoehe, hoehe / 2);
    ctx.fill();
    ctx.restore();
  }
}
