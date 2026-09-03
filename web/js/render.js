// Zeichnet die Singansicht auf ein Canvas.
//
// Das Spiel nutzt OpenGL; im Browser ist Canvas 2D der passende Ersatz - fuer
// Notenbalken und Text braucht es kein WebGL, und 2D laeuft ueberall.
//
// Dargestellt wird immer nur die AKTUELLE Zeile. Genau das macht das Spiel
// auch: Mehr passt nicht lesbar auf einen Bildschirm, und beim Singen schaut
// man ohnehin nur auf die naechsten Sekunden.

const TON_HOEHE = 14;      // Pixel je Halbton
const BALKEN_RUND = 6;

export class Renderer {
  constructor(canvas) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
  }

  // line: die aktuelle Zeile, beat: aktueller Schlag (auch zwischen ganzen),
  // sungMidi: erkannte Tonhoehe oder -1, treffer: bool je Note.
  draw(line, beat, sungMidi, treffer) {
    const { ctx, canvas } = this;
    const w = canvas.width, h = canvas.height;

    ctx.clearRect(0, 0, w, h);
    ctx.fillStyle = '#11131a';
    ctx.fillRect(0, 0, w, h);

    if (!line || line.notes.length === 0) return;

    const von = line.notes[0].start;
    const bis = line.notes[line.notes.length - 1].start +
                line.notes[line.notes.length - 1].length;
    const spanne = Math.max(1, bis - von);

    // Tonhoehen der Zeile mittig legen, statt fest zu skalieren: Sonst
    // rutschen tiefe Lieder aus dem Bild.
    const toene = line.notes.map((n) => n.pitch);
    const mitte = (Math.min(...toene) + Math.max(...toene)) / 2;

    const x = (b) => ((b - von) / spanne) * (w - 40) + 20;
    const y = (p) => h * 0.55 - (p - mitte) * TON_HOEHE;

    // Hilfslinien
    ctx.strokeStyle = '#1e2230';
    ctx.lineWidth = 1;
    for (let p = -12; p <= 12; p += 2) {
      ctx.beginPath();
      ctx.moveTo(0, y(mitte + p));
      ctx.lineTo(w, y(mitte + p));
      ctx.stroke();
    }

    // Notenbalken
    for (const note of line.notes) {
      const bx = x(note.start), bw = Math.max(4, x(note.start + note.length) - bx);
      const by = y(note.pitch) - TON_HOEHE / 2;

      ctx.fillStyle = note.type === 'golden' ? '#e8b23a'
                    : note.type === 'freestyle' ? '#3a4152'
                    : '#4a5570';
      this.balken(bx, by, bw, TON_HOEHE, BALKEN_RUND);

      if (treffer && treffer.get(note) > 0) {
        // Erreichter Anteil derselben Note, deckend darueber.
        ctx.fillStyle = note.type === 'golden' ? '#ffd978' : '#6ee7a8';
        this.balken(bx, by, bw * Math.min(1, treffer.get(note)), TON_HOEHE, BALKEN_RUND);
      }
    }

    // Gesungene Tonhoehe als waagerechter Strich an der Spielstelle
    if (sungMidi >= 0) {
      const px = x(beat);
      // Auf die Oktave der Zeile holen, sonst zeichnet man ausserhalb.
      let p = sungMidi - 60;
      while (p - mitte > 6) p -= 12;
      while (mitte - p > 6) p += 12;
      ctx.strokeStyle = '#7fd1ff';
      ctx.lineWidth = 4;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(px - 14, y(p));
      ctx.lineTo(px + 14, y(p));
      ctx.stroke();
    }

    // Spielstelle
    ctx.strokeStyle = '#ffffff44';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(x(beat), 0);
    ctx.lineTo(x(beat), h);
    ctx.stroke();

    this.text(line, beat, w, h);
  }

  balken(x, y, w, h, r) {
    const ctx = this.ctx;
    ctx.beginPath();
    ctx.roundRect(x, y, w, h, r);
    ctx.fill();
  }

  // Der Liedtext, die gerade faellige Silbe hervorgehoben.
  text(line, beat, w, h) {
    const ctx = this.ctx;
    ctx.font = '600 26px system-ui, sans-serif';
    ctx.textBaseline = 'alphabetic';

    const breiten = line.notes.map((n) => ctx.measureText(n.text).width);
    const gesamt = breiten.reduce((a, b) => a + b, 0);
    let cx = (w - gesamt) / 2;
    const cy = h - 34;

    line.notes.forEach((note, i) => {
      const aktiv = beat >= note.start && beat < note.start + note.length;
      ctx.fillStyle = aktiv ? '#ffd978' : (beat >= note.start ? '#8b93a4' : '#e8e8ea');
      ctx.fillText(note.text, cx, cy);
      cx += breiten[i];
    });
  }
}
