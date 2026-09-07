program testwebbridge;
(*
 * Prueft UWebBridge - die Uebergabestelle zwischen Spiel und Webserver.
 *
 * Wichtig sind zwei Zusagen:
 *   - Die Abschrift ist wirklich eine Abschrift; spaetere Aenderungen am
 *     Original duerfen nicht durchschlagen.
 *   - Gleichzeitiges Suchen und Veroeffentlichen ist gefahrlos.
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  Classes,
  USongFilter,
  UWebBridge;

var
  Bestanden, Fehlgeschlagen: integer;
  Bruecke: TWebBridge;
  Stoerung: boolean;

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

function BaueLieder(Anzahl: integer): TWebSongArray;
var I: integer;
begin
  SetLength(Result, Anzahl);
  for I := 0 to Anzahl - 1 do
  begin
    Result[I].Index := I;
    Result[I].Artist := 'Kuenstler ' + IntToStr(I mod 7);
    Result[I].Title := 'Lied ' + IntToStr(I);
    Result[I].Genre := 'Rock';
    Result[I].Language := 'German';
    Result[I].Edition := 'Best of';
    Result[I].Year := 1980 + (I mod 40);
  end;
end;

// Sucht dauernd, waehrend der Haupttest neu veroeffentlicht.
type
  TSucher = class(TThread)
    protected procedure Execute; override;
  end;

procedure TSucher.Execute;
var
  Treffer: TWebSongArray;
  I: integer;
begin
  for I := 1 to 2000 do
  begin
    try
      Treffer := Bruecke.FindSongs('lied', fltTitle, 50);
      // Jeder Treffer muss in sich stimmig sein - kein halb ueberschriebener
      // Datensatz.
      if (Length(Treffer) > 0) and (Treffer[0].Title = '') then
        Stoerung := true;
    except
      Stoerung := true;
    end;
  end;
end;

var
  Lieder, Treffer: TWebSongArray;
  Cmd: TWebCommand;
  I, Gesamt: integer;
  Sucher: array[0..3] of TSucher;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;
  Bruecke := TWebBridge.Create;

  WriteLn('Abschrift der Liederliste');
  Lieder := BaueLieder(50);
  Bruecke.PublishSongs(Lieder);
  Check('Anzahl kommt an', Bruecke.SongCount = 50, IntToStr(Bruecke.SongCount));

  // Das Original aendern - die Bruecke darf das NICHT mitbekommen.
  Lieder[0].Title := 'NACHTRAEGLICH GEAENDERT';
  Treffer := Bruecke.FindSongs('Lied 0', fltTitle, 10);
  Check('Aenderung am Original schlaegt nicht durch',
        (Length(Treffer) > 0) and (Treffer[0].Title = 'Lied 0'),
        IntToStr(Length(Treffer)));

  WriteLn('Suche');
  Treffer := Bruecke.FindSongs('lied', fltTitle, 1000);
  Check('alle Titel treffen', Length(Treffer) = 50, IntToStr(Length(Treffer)));
  Treffer := Bruecke.FindSongs('lied', fltTitle, 5);
  Check('Obergrenze wird eingehalten', Length(Treffer) = 5);
  Treffer := Bruecke.FindSongs('gibtesnicht', fltTitle, 10);
  Check('ohne Treffer leere Liste', Length(Treffer) = 0);

  // Die Suchsyntax des Spiels muss auch hier gelten.
  Treffer := Bruecke.FindSongs('lied AND 1980-1985', fltAll, 1000);
  Check('Jahresbereich wirkt', Length(Treffer) > 0);
  for I := 0 to High(Treffer) do
    if (Treffer[I].Year < 1980) or (Treffer[I].Year > 1985) then
      Check('Jahresbereich haelt sich an die Grenzen', false, IntToStr(Treffer[I].Year));
  Check('Jahresbereich haelt sich an die Grenzen', true);

  Treffer := Bruecke.FindSongs('!lied', fltTitle, 1000);
  Check('Ausschluss wirkt', Length(Treffer) = 0, IntToStr(Length(Treffer)));

  WriteLn('Suchregister');
  // Die Suchtexte werden beim Veroeffentlichen vorbereitet, nicht bei jeder
  // Anfrage. Der Fehler, der dabei droht: ein Register, das noch zur alten
  // Liste gehoert. Dann faende man Lieder, die es nicht mehr gibt - und die
  // neuen nicht.
  SetLength(Lieder, 1);
  Lieder[0].Index := 99;
  Lieder[0].Artist := 'Neuer';
  Lieder[0].Title := 'Titel';
  Lieder[0].Edition := '';
  Lieder[0].Genre := '';
  Lieder[0].Language := '';
  Lieder[0].Year := 0;
  Bruecke.PublishSongs(Lieder);

  Check('das neue Lied wird gefunden',
        Length(Bruecke.FindSongs('neuer', fltAll, 10)) = 1);
  Check('die alten nicht mehr',
        Length(Bruecke.FindSongs('lied', fltTitle, 10)) = 0,
        IntToStr(Length(Bruecke.FindSongs('lied', fltTitle, 10))));

  // Der gemeinsame Suchtext wird jetzt aus den schon vorbereiteten Feldern
  // zusammengesetzt. Geht dabei ein Trennzeichen verloren, klebten Interpret
  // und Titel aneinander und eine Suche ueber beide fiele aus.
  SetLength(Lieder, 1);
  Lieder[0].Index := 1;
  Lieder[0].Artist := 'Rock';
  Lieder[0].Title := 'Star';
  Lieder[0].Edition := 'Beste';
  Lieder[0].Genre := 'Pop';
  Lieder[0].Language := 'Deutsch';
  Lieder[0].Year := 1990;
  Bruecke.PublishSongs(Lieder);

  Check('Suche ueber zwei Felder hinweg',
        Length(Bruecke.FindSongs('rock star', fltAll, 10)) = 1);
  Check('Felder bleiben getrennt - kein zusammengeklebter Text',
        Length(Bruecke.FindSongs('rockstar', fltAll, 10)) = 0);
  Check('das Jahr steht im gemeinsamen Text',
        Length(Bruecke.FindSongs('1990', fltAll, 10)) = 1);
  Check('Sprache ebenso',
        Length(Bruecke.FindSongs('deutsch', fltAll, 10)) = 1);

  // Eine Feldsuche darf nicht in anderen Feldern fuendig werden.
  Check('Titelsuche findet den Interpreten nicht',
        Length(Bruecke.FindSongs('rock', fltTitle, 10)) = 0);
  Check('Interpretensuche findet den Titel nicht',
        Length(Bruecke.FindSongs('star', fltArtist, 10)) = 0);
  Check('Genresuche wirkt', Length(Bruecke.FindSongs('pop', fltGenre, 10)) = 1);
  Check('Jahresbereich wirkt weiterhin',
        Length(Bruecke.FindSongs('1985-1995', fltYear, 10)) = 1);
  Check('Grossschreibung ist egal',
        Length(Bruecke.FindSongs('ROCK', fltArtist, 10)) = 1);

  WriteLn('Sortierung und Nachladen');
  SetLength(Lieder, 5);
  Lieder[0].Index := 0; Lieder[0].Artist := 'Zappa';   Lieder[0].Title := 'Alpha';
  Lieder[1].Index := 0; Lieder[1].Artist := 'Anders';  Lieder[1].Title := 'Zulu';
  Lieder[2].Index := 0; Lieder[2].Artist := 'Anders';  Lieder[2].Title := 'Alpha';
  Lieder[3].Index := 0; Lieder[3].Artist := 'Meyer';   Lieder[3].Title := 'Beta';
  Lieder[4].Index := 0; Lieder[4].Artist := 'anders';  Lieder[4].Title := 'Beta';
  for I := 0 to 4 do
  begin
    Lieder[I].Edition := ''; Lieder[I].Genre := ''; Lieder[I].Language := '';
    Lieder[I].Year := 2000;
    Lieder[I].SelectIndex := 100 + I;   // Kennung fuer das Spiel
  end;
  Bruecke.PublishSongs(Lieder);

  Treffer := Bruecke.FindSongs('', fltAll, 100);
  Check('alle fuenf kommen zurueck', Length(Treffer) = 5, IntToStr(Length(Treffer)));
  Check('nach Interpret sortiert',
        (Treffer[0].Artist = 'Anders') and (Treffer[1].Artist = 'anders') and
        (Treffer[3].Artist = 'Meyer') and (Treffer[4].Artist = 'Zappa'),
        Treffer[0].Artist + ',' + Treffer[1].Artist + ',' + Treffer[2].Artist +
        ',' + Treffer[3].Artist + ',' + Treffer[4].Artist);
  Check('bei gleichem Interpreten nach Titel',
        (Treffer[0].Title = 'Alpha') and (Treffer[2].Title = 'Zulu'),
        Treffer[0].Title + ',' + Treffer[2].Title);

  // Der Index muss auf die Stelle in der sortierten Liste zeigen - ueber ihn
  // werden die Dateien nachgeschlagen.
  Stoerung := False;
  for I := 0 to High(Treffer) do
    if (Treffer[I].Index <> I) then Stoerung := True;
  Check('der Index zeigt auf die Stelle in der Liste', not Stoerung);

  // Die Kennung fuers Spiel darf sich beim Sortieren NICHT verschieben -
  // sonst startete das Spiel ein anderes Lied als angetippt.
  Check('die Kennung fuers Spiel wandert mit',
        (Treffer[4].SelectIndex = 100) and (Treffer[3].SelectIndex = 103),
        IntToStr(Treffer[4].SelectIndex) + ',' + IntToStr(Treffer[3].SelectIndex));

  // Nachladen: seitenweise geholt muss dasselbe herauskommen wie am Stueck.
  Treffer := Bruecke.FindSongs('', fltAll, 2, 0);
  Check('erste Seite hat zwei', Length(Treffer) = 2);
  Check('und faengt vorne an', Treffer[0].Artist = 'Anders');
  // Stelle 2 ist 'Anders / Zulu': Bei gleichem Interpreten entscheidet der
  // Titel, und 'Beta' (Stelle 1) kommt vor 'Zulu'.
  Treffer := Bruecke.FindSongs('', fltAll, 2, 2);
  Check('zweite Seite setzt fort',
        (Length(Treffer) = 2) and (Treffer[0].Title = 'Zulu') and
        (Treffer[1].Artist = 'Meyer'),
        Treffer[0].Artist + '/' + Treffer[0].Title + ',' + Treffer[1].Artist);
  Treffer := Bruecke.FindSongs('', fltAll, 2, 4);
  Check('letzte Seite hat den Rest',
        (Length(Treffer) = 1) and (Treffer[0].Artist = 'Zappa'),
        IntToStr(Length(Treffer)));
  Treffer := Bruecke.FindSongs('', fltAll, 2, 99);
  Check('hinter dem Ende kommt nichts', Length(Treffer) = 0);
  Treffer := Bruecke.FindSongs('', fltAll, 2, -5);
  Check('ein negativer Versatz zaehlt als null', Length(Treffer) = 2);

  // Auch mit Suchbegriff muss der Versatz auf die TREFFER zaehlen, nicht auf
  // alle Lieder.
  Treffer := Bruecke.FindSongs('alpha', fltTitle, 10, 1);
  Check('Versatz zaehlt die Treffer, nicht die Lieder',
        (Length(Treffer) = 1) and (Treffer[0].Artist = 'Zappa'),
        IntToStr(Length(Treffer)));

  // Gesamtzahl: zaehlt ALLE Treffer, nicht nur die Seite - sonst wuerfelte
  // das Zufallslied nur unter den ersten Max Treffern.
  Treffer := Bruecke.FindSongs('', fltAll, 2, 0, Gesamt);
  Check('Gesamtzahl zaehlt trotz kleiner Seite alle',
        Gesamt = 5, IntToStr(Gesamt));
  Check('die Seite selbst bleibt trotzdem klein', Length(Treffer) = 2);
  Treffer := Bruecke.FindSongs('alpha', fltTitle, 10, 0, Gesamt);
  Check('Gesamtzahl gilt fuer die Treffer, nicht fuer alle Lieder',
        Gesamt = 2, IntToStr(Gesamt));
  Treffer := Bruecke.FindSongs('gibtesnicht', fltAll, 10, 0, Gesamt);
  Check('ohne Treffer ist auch die Gesamtzahl null', Gesamt = 0);

  WriteLn('Befehle');
  Check('anfangs kein Befehl', not Bruecke.NextCommand(Cmd));
  Bruecke.PostCommand(wckStart, 42);
  Bruecke.PostCommand(wckStart, 7);
  Check('erster Befehl kommt zuerst',
        Bruecke.NextCommand(Cmd) and (Cmd.SongIndex = 42), IntToStr(Cmd.SongIndex));
  Check('dann der zweite',
        Bruecke.NextCommand(Cmd) and (Cmd.SongIndex = 7));
  Check('danach ist die Schlange leer', not Bruecke.NextCommand(Cmd));
  Check('und die Art stimmt', Cmd.Kind = wckNone);

  // Ein haengendes Spiel darf den Speicher nicht volllaufen lassen.
  for I := 1 to 500 do
    Bruecke.PostCommand(wckStart, I);
  I := 0;
  while Bruecke.NextCommand(Cmd) do
    Inc(I);
  Check('Schlange ist nach oben begrenzt', (I > 0) and (I <= 64), IntToStr(I));

  WriteLn('Gleichzeitig suchen und veroeffentlichen');
  Stoerung := false;
  for I := 0 to High(Sucher) do
    Sucher[I] := TSucher.Create(false);
  for I := 1 to 200 do
    Bruecke.PublishSongs(BaueLieder(20 + (I mod 60)));
  for I := 0 to High(Sucher) do
    Sucher[I].WaitFor;
  for I := 0 to High(Sucher) do
    Sucher[I].Free;
  Check('kein Absturz, keine halben Datensaetze', not Stoerung);
  Check('Stand wurde hochgezaehlt', Bruecke.Stand > 200, IntToStr(Bruecke.Stand));

  Bruecke.Free;

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
