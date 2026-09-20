program testwebvorschau;
(*
 * Prueft UWebVorschau - die Schnipsel fuer die Liedauswahl.
 *
 * Der wichtigste Teil ist VorschauStelle: Sie muss auf die Nachkommastelle
 * dasselbe liefern wie previewRange() in web/js/song.js, denn beide
 * beschreiben dieselbe Regel aus dem Spiel (TSong.GetPreviewRange). Die
 * Tabelle unten steht wortgleich in web/tests/run.mjs - laeuft eine Seite
 * weg, faellt es auf.
 *
 * Das Schneiden selbst braucht ffmpeg. Fehlt es, wird dieser Teil
 * uebersprungen statt fehlzuschlagen.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  process,
  UWebVorschau;

var
  Bestanden, Fehlgeschlagen, Uebersprungen: integer;

procedure Check(const Was: string; Bedingung: boolean; const Detail: string = '');
begin
  if Bedingung then
  begin
    Inc(Bestanden);
    WriteLn('  OK   ', Was);
  end
  else
  begin
    Inc(Fehlgeschlagen);
    WriteLn('  FEHL ', Was, '   ', Detail);
  end;
end;

procedure Ueberspringe(const Was: string);
begin
  Inc(Uebersprungen);
  WriteLn('  --   ', Was, ' (uebersprungen)');
end;

// Dieselben Faelle wie in web/tests/run.mjs.
procedure PruefeStelle;

  procedure Gleich(const Was: string; ps, st, fi, du, soll: double);
  var
    Ist: double;
  begin
    Ist := VorschauStelle(ps, st, fi, du);
    Check(Was, Abs(Ist - soll) < 0.0001,
          Format('%.4f statt %.4f', [Ist, soll]));
  end;

begin
  WriteLn('Startstelle (muss previewRange() entsprechen)');
  Gleich('ohne Dauer bleibt es 0',            0,   0,   0,    0,   0);
  Gleich('ein Viertel hinein',                0,   0,   0,  200,  50);
  Gleich('#PREVIEWSTART gilt',               45,   0,   0,  200,  45);
  // Liegt die Stelle hinter dem Lied, zaehlt sie nicht - sonst liefe die
  // Vorschau ins Leere.
  Gleich('#PREVIEWSTART hinter dem Ende faellt weg',
                                             45,   0,   0,   40,  10);
  Gleich('#START verschiebt den Anfang',      0,  10,   0,  200,  57.5);
  Gleich('#END verschiebt das Ende',          0,  10, 180,  200,  52.5);
  // Die Sonderregel aus dem Spiel: ueber zwei Minuten Versatz wird NICHT
  // gedeckelt, sondern auf eine Minute zurueckgesetzt.
  Gleich('ueber 120 s Versatz wird zu 60 s',  0,   0,   0, 1000,  60);
  Gleich('genau an der Grenze bleibt es',     0,   0,   0,  480, 120);
  Gleich('Ende vor Anfang: ganzes Lied',      0, 100,  50,  200,  50);
  Gleich('negativer #PREVIEWSTART zaehlt nicht',
                                             -5,   0,   0,  200,  50);
  Gleich('kurzes Lied',                       0,   0,   0,  100,  25);
end;

procedure PruefePfad;
begin
  WriteLn;
  WriteLn('Wo der Schnipsel liegt');
  Check('neben der Tondatei',
        VorschauPfad('/lieder/A/ton.m4a') = '/lieder/A/ton.m4a.vorschau.mp3',
        VorschauPfad('/lieder/A/ton.m4a'));
  // An den GANZEN Namen angehaengt, nicht die Endung ersetzt: Sonst zeigten
  // "Lied.mp3" und "Lied.m4a" im selben Ordner auf dieselbe Vorschau.
  Check('mp3 und m4a kollidieren nicht',
        VorschauPfad('/x/Lied.mp3') <> VorschauPfad('/x/Lied.m4a'));
  Check('ohne Tondatei kein Pfad', VorschauPfad('') = '');
end;

// Baut eine Tondatei mit ffmpeg und schneidet daraus. Der eigentliche Zweck:
// zeigen, dass auch eine .m4a funktioniert - ein MP4 laesst sich NICHT
// byteweise schneiden, und genau deshalb wird hier neu kodiert.
procedure PruefeSchneiden;
var
  Ordner, Quelle, Ziel: UTF8String;
  Dauer: double;

  function BaueTon(const Datei, Codec: UTF8String; Sekunden: integer): boolean;
  var
    P: TProcess;
  begin
    P := TProcess.Create(nil);
    try
      P.Executable := 'ffmpeg';
      P.Parameters.Add('-v'); P.Parameters.Add('error');
      P.Parameters.Add('-f'); P.Parameters.Add('lavfi');
      P.Parameters.Add('-i');
      P.Parameters.Add(Format('sine=frequency=440:duration=%d:sample_rate=44100',
                              [Sekunden]));
      P.Parameters.Add('-ac'); P.Parameters.Add('1');
      P.Parameters.Add('-codec:a'); P.Parameters.Add(Codec);
      P.Parameters.Add('-b:a'); P.Parameters.Add('128k');
      P.Parameters.Add('-y');
      P.Parameters.Add(Datei);
      P.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
      P.ShowWindow := swoHIDE;
      try
        P.Execute;
        Result := (P.ExitStatus = 0) and FileExists(Datei);
      except
        Result := False;
      end;
    finally
      P.Free;
    end;
  end;

begin
  WriteLn;
  WriteLn('Schneiden');
  if not FfmpegDa then
  begin
    Ueberspringe('ffmpeg/ffprobe fehlen');
    Exit;
  end;

  Ordner := IncludeTrailingPathDelimiter(
    GetTempDir + 'usdxvorschau' + IntToStr(Random(100000)));
  ForceDirectories(Ordner);
  try
    // --- m4a, der Fall, um den es geht ---
    Quelle := Ordner + 'ton.m4a';
    if not BaueTon(Quelle, 'aac', 90) then
    begin
      Ueberspringe('ffmpeg kann hier kein aac');
      Exit;
    end;

    Dauer := TonDauer(Quelle);
    Check('Dauer wird erkannt', Abs(Dauer - 90) < 1.0, Format('%.2f', [Dauer]));

    Ziel := VorschauPfad(Quelle);
    Check('noch keine Vorschau da', not VorschauAktuell(Quelle));

    Check('Schnipsel entsteht', ErzeugeVorschau(Quelle, Ziel, 40));
    Check('und liegt neben der Tondatei', FileExists(Ziel));
    Check('jetzt gilt sie als aktuell', VorschauAktuell(Quelle));

    // Die Laengenbegrenzung ist der ganze Grund fuer das Neukodieren.
    Check('Schnipsel ist hoechstens eine halbe Minute',
          TonDauer(Ziel) <= VORSCHAU_SEKUNDEN + 1.0,
          Format('%.2f s', [TonDauer(Ziel)]));
    Check('und nicht leer', DateiGroesse(Ziel) > 1024,
          IntToStr(DateiGroesse(Ziel)));
    // Und er ist deutlich kleiner als das Lied - sonst waere nichts gewonnen.
    Check('deutlich kleiner als die Tondatei',
          DateiGroesse(Ziel) < DateiGroesse(Quelle),
          Format('%d vs %d', [DateiGroesse(Ziel), DateiGroesse(Quelle)]));

    // Liegt die Stelle hinter dem Lied, darf keine leere Datei zurueck-
    // bleiben, die beim naechsten Start fuer fertig gehalten wird.
    DeleteFile(Ziel);
    Check('Stelle hinter dem Ende ergibt keinen Schnipsel',
          not ErzeugeVorschau(Quelle, Ziel, 500));
    Check('und laesst nichts liegen', not FileExists(Ziel));
    Check('auch keine halbe Nebendatei', not FileExists(Ziel + '.teil'));

    // --- mp3, der andere verbreitete Fall ---
    Quelle := Ordner + 'ton.mp3';
    if BaueTon(Quelle, 'libmp3lame', 40) then
    begin
      Ziel := VorschauPfad(Quelle);
      Check('auch aus mp3 entsteht ein Schnipsel',
            ErzeugeVorschau(Quelle, Ziel, 5));
      Check('mit hoechstens einer halben Minute',
            TonDauer(Ziel) <= VORSCHAU_SEKUNDEN + 1.0,
            Format('%.2f s', [TonDauer(Ziel)]));
      DeleteFile(Ziel);
    end;

    Check('freier Platz laesst sich feststellen', FreiMB(Ordner) >= 0,
          IntToStr(FreiMB(Ordner)));
  finally
    DeleteFile(Ordner + 'ton.m4a');
    DeleteFile(Ordner + 'ton.m4a' + VORSCHAU_ENDUNG);
    DeleteFile(Ordner + 'ton.mp3');
    DeleteFile(Ordner + 'ton.mp3' + VORSCHAU_ENDUNG);
    RemoveDir(Ordner);
  end;
end;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;
  Uebersprungen := 0;

  PruefeStelle;
  PruefePfad;
  PruefeSchneiden;

  WriteLn;
  if (Uebersprungen > 0) then
    WriteLn(Format('%d bestanden, %d fehlgeschlagen, %d uebersprungen',
                   [Bestanden, Fehlgeschlagen, Uebersprungen]))
  else
    WriteLn(Format('%d bestanden, %d fehlgeschlagen',
                   [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
