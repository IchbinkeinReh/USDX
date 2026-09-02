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
  I: integer;
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
