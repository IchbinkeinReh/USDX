unit UWebZaehler;

(*
 * Haelt fest, wann welches Lied im Browser gesungen wurde.
 *
 * Zwei Dateien, beide schlichter Text mit Tabulatoren:
 *
 *   web-gesungen.tsv  je Auffuehrung eine Zeile (Zeitpunkt, Interpret, Titel)
 *   web-zaehler.tsv   je Lied eine Zeile mit der Gesamtzahl
 *
 * Die Zaehlerdatei ist aus dem Protokoll ableitbar - sie steht trotzdem
 * daneben, damit "wie oft" nicht bedeutet, dreissigtausend Zeilen zu lesen.
 * Massgeblich ist das Protokoll; die Zaehler werden daraus aufgebaut.
 *
 * Warum nicht die Datenbank des Spiels: UDataBase haengt ueber USong und
 * USongs an der Grafikkette und laesst sich im kopflosen Betrieb nicht
 * einmal uebersetzen. Ausserdem kennt sie nur "wie oft", nicht "wann".
 *
 * WANN gezaehlt wird, entscheidet der Aufrufer - beim ersten Byte Ton, das
 * an einen Saenger geht. Diese Einheit kuemmert sich nur darum, dass
 * derselbe Durchgang nicht zweimal zaehlt.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  SyncObjs;

const
  PROTOKOLL_NAME = 'web-gesungen.tsv';
  ZAEHLER_NAME   = 'web-zaehler.tsv';

  // Wie viele Durchgaenge gemerkt werden, um Doppelzaehlungen zu verhindern.
  //
  // Ein Durchgang wird vom Browser gewuerfelt und beim Neuladen aus dem
  // sessionStorage wieder mitgeschickt. Gemerkt werden muss er nur so lange,
  // wie ein Lied dauert - ein paar hundert reichen fuer jede Feier.
  MAX_DURCHGAENGE = 512;

type
  TWebZaehler = class
    private
      fLock: TCriticalSection;
      fOrdner: UTF8String;
      // Schon gezaehlte Durchgaenge, als "durchgang|liednummer".
      fGesehen: array of UTF8String;
      function SchonGezaehlt(const Schluessel: UTF8String): boolean;
      procedure Merke(const Schluessel: UTF8String);
      procedure SchreibeProtokoll(const Zeitpunkt, Artist, Titel: UTF8String);
      procedure ErhoeheZaehler(const Artist, Titel: UTF8String);
    public
      // Ordner, in dem die beiden Dateien liegen. Leer heisst: nicht
      // schreiben (dann laeuft alles weiter, es wird nur nichts gezaehlt).
      constructor Create(const AOrdner: UTF8String);
      destructor Destroy; override;

      // Zaehlt eine Auffuehrung, wenn dieser Durchgang noch nicht zaehlte.
      // Rueckgabe: True, wenn tatsaechlich gezaehlt wurde.
      //
      // Durchgang ist die Kennung EINES Singens. Derselbe Durchgang zaehlt
      // nur einmal - deshalb aendert ein Neuladen des Browsers nichts, waehrend
      // ein zweites Singen desselben Liedes eine neue Kennung mitbringt und
      // damit wieder zaehlt.
      function Zaehle(const Durchgang: UTF8String; SongIndex: integer;
                      const Artist, Titel: UTF8String): boolean;

      // Wie oft ein Lied bisher gesungen wurde, aus der Zaehlerdatei.
      function Anzahl(const Artist, Titel: UTF8String): integer;

      property Ordner: UTF8String read fOrdner;
  end;

// Wohin die beiden Dateien gehoeren: der Ordner der config.ini, sonst
// ~/.ultrastardx. Leer, wenn sich nichts Schreibbares finden laesst.
function ZaehlerOrdner(const IniPfad: UTF8String): UTF8String;

// Eine Zeile fuer die Protokolldatei. Getrennt, damit sie pruefbar ist.
function ProtokollZeile(const Zeitpunkt, Artist, Titel: UTF8String): UTF8String;

// Tabulatoren und Zeilenumbrueche aus einem Feld entfernen.
//
// Ohne das zerlegt ein Titel mit Tabulator die Datei in zusaetzliche
// Spalten, und ein Zeilenumbruch macht aus einer Auffuehrung zwei.
function Saeubere(const S: UTF8String): UTF8String;

implementation

function Saeubere(const S: UTF8String): UTF8String;
var
  I: integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if (Result[I] = #9) or (Result[I] = #10) or (Result[I] = #13) then
      Result[I] := ' ';
  Result := Trim(Result);
end;

function ProtokollZeile(const Zeitpunkt, Artist, Titel: UTF8String): UTF8String;
begin
  Result := Saeubere(Zeitpunkt) + #9 + Saeubere(Artist) + #9 + Saeubere(Titel);
end;

// Laesst sich in diesem Ordner wirklich schreiben?
//
// Nicht nur DirectoryExists: Unter systemd mit ProtectHome=read-only oder
// ProtectSystem=strict ist der Ordner da und trotzdem schreibgeschuetzt.
// Ohne diese Probe meldete der Start "Zaehlung: ..." und es wurde nie etwas
// mitgeschrieben - eine Meldung, die genau das Gegenteil behauptet.
function Beschreibbar(const Ordner: UTF8String): boolean;
var
  Probe: UTF8String;
  F: TFileStream;
begin
  Result := False;
  if (Ordner = '') or not DirectoryExists(Ordner) then Exit;
  Probe := IncludeTrailingPathDelimiter(Ordner) +
           '.schreibprobe-' + IntToStr(Random(1000000));
  try
    F := TFileStream.Create(Probe, fmCreate);
    F.Free;
    DeleteFile(Probe);
    Result := True;
  except
    Result := False;
  end;
end;

function ZaehlerOrdner(const IniPfad: UTF8String): UTF8String;
var
  Heim, Kandidat: UTF8String;
begin
  Result := '';
  // Erste Wahl: dorthin, wo auch die Einstellungen liegen.
  if (IniPfad <> '') then
  begin
    Kandidat := ExtractFilePath(IniPfad);
    if Beschreibbar(Kandidat) then
    begin
      Result := Kandidat;
      Exit;
    end;
  end;

  // Zweite Wahl: ein Zustandsordner, wie systemd ihn ueber
  // StateDirectory= bereitstellt. Dort darf ein Dienst schreiben, auch wenn
  // sonst alles schreibgeschuetzt ist.
  Kandidat := GetEnvironmentVariable('STATE_DIRECTORY');
  if (Kandidat <> '') then
  begin
    Kandidat := IncludeTrailingPathDelimiter(Kandidat);
    if Beschreibbar(Kandidat) then
    begin
      Result := Kandidat;
      Exit;
    end;
  end;

  Heim := GetEnvironmentVariable('HOME');
  if (Heim = '') then Exit;
  Kandidat := IncludeTrailingPathDelimiter(Heim) + '.ultrastardx' + PathDelim;
  if not DirectoryExists(Kandidat) then
    if not ForceDirectories(Kandidat) then Exit;
  if not Beschreibbar(Kandidat) then Exit;
  Result := Kandidat;
end;

constructor TWebZaehler.Create(const AOrdner: UTF8String);
begin
  inherited Create;
  fLock := TCriticalSection.Create;
  if (AOrdner <> '') then
    fOrdner := IncludeTrailingPathDelimiter(AOrdner)
  else
    fOrdner := '';
end;

destructor TWebZaehler.Destroy;
begin
  SetLength(fGesehen, 0);
  fLock.Free;
  inherited;
end;

function TWebZaehler.SchonGezaehlt(const Schluessel: UTF8String): boolean;
var
  I: integer;
begin
  Result := False;
  for I := 0 to High(fGesehen) do
    if (fGesehen[I] = Schluessel) then
    begin
      Result := True;
      Exit;
    end;
end;

procedure TWebZaehler.Merke(const Schluessel: UTF8String);
var
  I, N: integer;
begin
  N := Length(fGesehen);
  if (N >= MAX_DURCHGAENGE) then
  begin
    // Aeltesten herausschieben. Der Reihe nach, nicht sortiert - bei dieser
    // Groessenordnung ist das billiger als jede Buchhaltung darueber.
    for I := 0 to N - 2 do
      fGesehen[I] := fGesehen[I + 1];
    fGesehen[N - 1] := Schluessel;
    Exit;
  end;
  SetLength(fGesehen, N + 1);
  fGesehen[N] := Schluessel;
end;

// Haengt eine Zeile an. Bewusst jedes Mal oeffnen und schliessen statt eine
// offene Datei zu halten: So steht nach jeder Auffuehrung alles auf der
// Platte, auch wenn der Rechner gleich darauf ausgeht.
procedure TWebZaehler.SchreibeProtokoll(const Zeitpunkt, Artist,
                                        Titel: UTF8String);
var
  Strom: TFileStream;
  Zeile: UTF8String;
  Pfad: UTF8String;
begin
  if (fOrdner = '') then Exit;
  Pfad := fOrdner + PROTOKOLL_NAME;
  Zeile := ProtokollZeile(Zeitpunkt, Artist, Titel) + LineEnding;
  try
    if FileExists(Pfad) then
    begin
      Strom := TFileStream.Create(Pfad, fmOpenWrite or fmShareDenyNone);
      Strom.Seek(0, soEnd);
    end
    else
      Strom := TFileStream.Create(Pfad, fmCreate);
    try
      Strom.WriteBuffer(Zeile[1], Length(Zeile));
    finally
      Strom.Free;
    end;
  except
    // Nur lesbarer Ordner, Platte voll: Das darf das Singen nicht stoeren.
  end;
end;

procedure TWebZaehler.ErhoeheZaehler(const Artist, Titel: UTF8String);
var
  Zeilen: TStringList;
  Pfad, Schluessel, Zeile: UTF8String;
  I, Trenner, Wert: integer;
  Gefunden: boolean;
begin
  if (fOrdner = '') then Exit;
  Pfad := fOrdner + ZAEHLER_NAME;
  Schluessel := Saeubere(Artist) + #9 + Saeubere(Titel);
  Zeilen := TStringList.Create;
  try
    try
      if FileExists(Pfad) then
        Zeilen.LoadFromFile(Pfad);
    except
      Zeilen.Clear;
    end;

    Gefunden := False;
    for I := 0 to Zeilen.Count - 1 do
    begin
      Zeile := Zeilen[I];
      // Die Zahl steht hinter dem LETZTEN Tabulator - Interpret und Titel
      // koennen selbst keine enthalten, Saeubere hat sie herausgenommen.
      Trenner := LastDelimiter(#9, Zeile);
      if (Trenner <= 0) then Continue;
      if (Copy(Zeile, 1, Trenner - 1) = Schluessel) then
      begin
        Wert := StrToIntDef(Copy(Zeile, Trenner + 1, Length(Zeile)), 0);
        Zeilen[I] := Schluessel + #9 + IntToStr(Wert + 1);
        Gefunden := True;
        Break;
      end;
    end;
    if not Gefunden then
      Zeilen.Add(Schluessel + #9 + '1');

    try
      Zeilen.SaveToFile(Pfad);
    except
      // siehe SchreibeProtokoll
    end;
  finally
    Zeilen.Free;
  end;
end;

function TWebZaehler.Zaehle(const Durchgang: UTF8String; SongIndex: integer;
                            const Artist, Titel: UTF8String): boolean;
var
  Schluessel, Zeitpunkt: UTF8String;
begin
  Result := False;
  // Ohne Durchgangskennung wird nicht gezaehlt. Sonst zaehlte jeder erneute
  // Abruf mit - und der Browser holt den Ton in vielen Stuecken.
  if (Durchgang = '') then Exit;

  Schluessel := Durchgang + '|' + IntToStr(SongIndex);

  fLock.Acquire;
  try
    if SchonGezaehlt(Schluessel) then Exit;
    Merke(Schluessel);

    Zeitpunkt := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now);
    SchreibeProtokoll(Zeitpunkt, Artist, Titel);
    ErhoeheZaehler(Artist, Titel);
    Result := True;
  finally
    fLock.Release;
  end;
end;

function TWebZaehler.Anzahl(const Artist, Titel: UTF8String): integer;
var
  Zeilen: TStringList;
  Pfad, Schluessel, Zeile: UTF8String;
  I, Trenner: integer;
begin
  Result := 0;
  if (fOrdner = '') then Exit;
  Pfad := fOrdner + ZAEHLER_NAME;
  if not FileExists(Pfad) then Exit;
  Schluessel := Saeubere(Artist) + #9 + Saeubere(Titel);

  fLock.Acquire;
  try
    Zeilen := TStringList.Create;
    try
      try
        Zeilen.LoadFromFile(Pfad);
      except
        Exit;
      end;
      for I := 0 to Zeilen.Count - 1 do
      begin
        Zeile := Zeilen[I];
        Trenner := LastDelimiter(#9, Zeile);
        if (Trenner <= 0) then Continue;
        if (Copy(Zeile, 1, Trenner - 1) = Schluessel) then
        begin
          Result := StrToIntDef(Copy(Zeile, Trenner + 1, Length(Zeile)), 0);
          Exit;
        end;
      end;
    finally
      Zeilen.Free;
    end;
  finally
    fLock.Release;
  end;
end;

end.
