program testparallelload;
(*
 * Prueft das Verteilmuster des parallelen Einlesens.
 *
 * NICHT das echte Einlesen - dafuer braucht es das Spiel. Geprueft wird der
 * Mechanismus, den USongs.LoadSongFiles benutzt: Arbeiter holen sich Indizes
 * per InterLockedIncrement und legen Ergebnisse auf ihrem eigenen Platz ab.
 *
 * Die beiden Zusagen, auf die es ankommt:
 *   - jede Aufgabe wird GENAU einmal erledigt
 *   - das Ergebnis steht am Ende in Eingabereihenfolge, unabhaengig davon,
 *     welcher Thread wann fertig wurde
 *)
{$MODE Delphi}

uses
  {$IFDEF UNIX}
  cthreads,   // MUSS unter Unix die erste Unit sein, sonst gibt es keine Threads
  {$ENDIF}
  SysUtils,
  Classes;

type
  TTestWorker = class(TThread)
    protected
      procedure Execute; override;
  end;

var
  Bestanden, Fehlgeschlagen: integer;
  Aufgaben: integer;
  Naechste: longint;
  Fertige: longint;
  Ergebnis: array of integer;
  Bearbeitet: array of integer;

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

procedure TTestWorker.Execute;
var
  Index, K: integer;
  Summe: int64;
begin
  while not Terminated do
  begin
    Index := InterLockedIncrement(Naechste) - 1;
    if (Index > High(Ergebnis)) then
      Break;

    // Ungleich viel Arbeit je Aufgabe - so wird die Reihenfolge der
    // Fertigstellung garantiert eine andere als die der Indizes.
    Summe := 0;
    for K := 1 to 200 + (Index mod 17) * 400 do
      Summe := Summe + K;

    Ergebnis[Index] := Index * 2;
    InterLockedIncrement(Bearbeitet[Index]);
    InterLockedIncrement(Fertige);
  end;
end;

var
  I, Threads: integer;
  Worker: array of TTestWorker;
  AllesRichtig, GenauEinmal: boolean;

begin
  Bestanden := 0;
  Fehlgeschlagen := 0;
  Aufgaben := 2000;
  Threads := 6;

  SetLength(Ergebnis, Aufgaben);
  SetLength(Bearbeitet, Aufgaben);
  for I := 0 to Aufgaben - 1 do
  begin
    Ergebnis[I] := -1;
    Bearbeitet[I] := 0;
  end;
  Naechste := 0;
  Fertige := 0;

  WriteLn('Verteilung auf ', Threads, ' Threads, ', Aufgaben, ' Aufgaben');

  SetLength(Worker, Threads);
  for I := 0 to Threads - 1 do
    Worker[I] := TTestWorker.Create(false);
  for I := 0 to Threads - 1 do
    Worker[I].WaitFor;
  for I := 0 to Threads - 1 do
    Worker[I].Free;

  Check('alle Aufgaben gezaehlt', Fertige = Aufgaben,
        IntToStr(Fertige) + ' von ' + IntToStr(Aufgaben));

  GenauEinmal := true;
  for I := 0 to Aufgaben - 1 do
    if (Bearbeitet[I] <> 1) then
      GenauEinmal := false;
  Check('jede Aufgabe genau einmal bearbeitet', GenauEinmal);

  AllesRichtig := true;
  for I := 0 to Aufgaben - 1 do
    if (Ergebnis[I] <> I * 2) then
      AllesRichtig := false;
  Check('Ergebnis steht am richtigen Platz - Reihenfolge bleibt', AllesRichtig);

  Check('keine Luecke', Ergebnis[0] = 0);
  Check('bis zum letzten', Ergebnis[Aufgaben - 1] = (Aufgaben - 1) * 2);

  WriteLn;
  WriteLn(Format('%d bestanden, %d fehlgeschlagen', [Bestanden, Fehlgeschlagen]));
  if Fehlgeschlagen > 0 then
    Halt(1);
end.
