unit USongHeader;

(*
 * Liest den Kopf einer Lieddatei - ohne SDL, ohne OpenGL, ohne das Spiel.
 *
 * WARUM NOCH EIN LESER, wo USong das doch kann:
 *
 * USong haengt ueber URenderer und UMusic an der ganzen Grafik- und
 * Tonkette. Auf einem Rechner ohne Bildschirm laesst sich davon nichts
 * benutzen - schon das Uebersetzen scheitert an sdl2_image. Fuer die
 * Weboberflaeche braucht es aber nur die Kopfdaten und den Dateinamen: Die
 * Noten liest der Browser selbst aus derselben .txt.
 *
 * Bewusst NICHT nachgebaut wird deshalb alles, was mit Noten, Titelbildern,
 * Videos oder der Bestenliste zu tun hat. Was hier steht, ist das, was in
 * einer Liederliste sichtbar ist.
 *
 * Die eine Regel, die man leicht falsch nachbaut: Ob ein Lied ein Duett ist,
 * entscheidet USDX an der ERSTEN Zeile des Notenteils. Faengt sie mit P an,
 * ist es eines - eine Kopfzeile dazu gibt es nicht.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes;

type
  TSongHeader = record
    TxtPath:   UTF8String;   // vollstaendiger Pfad der .txt
    AudioPath: UTF8String;   // vollstaendiger Pfad der Tondatei, '' wenn keine
    VideoPath: UTF8String;   // #VIDEO, '' wenn keins
    BackgPath: UTF8String;   // #BACKGROUND, '' wenn keins
    VideoGap:  double;       // #VIDEOGAP in Sekunden
    Artist:    UTF8String;
    Title:     UTF8String;
    Edition:   UTF8String;
    Genre:     UTF8String;
    Language:  UTF8String;
    Year:      integer;
    Duet:      boolean;
  end;

// Liest die Kopfdaten. false, wenn die Datei sich nicht oeffnen laesst oder
// weder Titel noch Interpret enthaelt - dann ist es keine Lieddatei.
function ReadSongHeader(const FileName: UTF8String;
                        out Header: TSongHeader): boolean;

implementation

const
  // Weiter zu lesen lohnt nicht: Der Kopf steht am Anfang, und die erste
  // Zeile des Notenteils beendet die Suche ohnehin. Die Grenze schuetzt
  // davor, dass eine kaputte Datei ohne Zeilenumbrueche alles aufhaelt.
  MAX_KOPFZEILEN = 200;

// Schneidet ein BOM ab. Ohne das heisst die erste Kopfzeile nicht 'TITLE',
// sondern enthaelt drei unsichtbare Bytes davor und wird nie erkannt.
function OhneBOM(const S: UTF8String): UTF8String;
begin
  if (Length(S) >= 3) and (S[1] = #$EF) and (S[2] = #$BB) and (S[3] = #$BF) then
    Result := Copy(S, 4, Length(S))
  else
    Result := S;
end;

// Jahreszahlen stehen mal als '1994', mal als '1994-05-01'. Nur die ersten
// vier Ziffern zaehlen.
function LiesJahr(const S: UTF8String): integer;
var
  Ziffern: UTF8String;
  I: integer;
begin
  Ziffern := '';
  for I := 1 to Length(S) do
  begin
    if (S[I] >= '0') and (S[I] <= '9') then
      Ziffern := Ziffern + S[I]
    else
      Break;
  end;
  Result := StrToIntDef(Ziffern, 0);
end;

function ReadSongHeader(const FileName: UTF8String;
                        out Header: TSongHeader): boolean;
var
  Datei: TextFile;
  Zeile, Schluessel, Wert: UTF8String;
  Trenner, Gelesen: integer;
  Ordner, TonName, VideoName, BildName: UTF8String;

  // Loest einen Dateinamen aus dem Kopf gegen den Ordner der .txt auf.
  // Leer, wenn nichts dasteht oder die Datei fehlt.
  function Daneben(const Name: UTF8String): UTF8String;
  begin
    Result := '';
    if (Name = '') then Exit;
    // Absolute Pfade kommen vor und bleiben stehen. Sonst gilt der Name
    // relativ zur .txt - Rueckstriche aus Windows-Dateien mit umsetzen.
    if (Name[1] = PathDelim) or (Pos(':', Name) = 2) then
      Result := Name
    else
      Result := Ordner + StringReplace(Name, '\', PathDelim, [rfReplaceAll]);
    if not FileExists(Result) then
      Result := '';
  end;
begin
  Result := False;
  FillChar(Header, SizeOf(Header), 0);
  Header.TxtPath := FileName;
  Header.AudioPath := '';
  Header.Artist := '';
  Header.Title := '';
  Header.Edition := '';
  Header.Genre := '';
  Header.Language := '';
  Header.VideoPath := '';
  Header.BackgPath := '';
  Header.VideoGap := 0;
  TonName := '';
  VideoName := '';
  BildName := '';

  AssignFile(Datei, FileName);
  {$I-}
  Reset(Datei);
  {$I+}
  if (IOResult <> 0) then
    Exit;

  try
    Gelesen := 0;
    while not Eof(Datei) and (Gelesen < MAX_KOPFZEILEN) do
    begin
      {$I-}
      ReadLn(Datei, Zeile);
      {$I+}
      if (IOResult <> 0) then Break;
      Inc(Gelesen);

      if (Gelesen = 1) then
        Zeile := OhneBOM(Zeile);
      Zeile := Trim(Zeile);
      if (Zeile = '') then Continue;

      if (Zeile[1] <> '#') then
      begin
        // Erste Zeile des Notenteils: Faengt sie mit P an, ist es ein Duett.
        // Danach gibt es hier nichts mehr zu holen.
        Header.Duet := (UpCase(Zeile[1]) = 'P');
        Break;
      end;

      Trenner := Pos(':', Zeile);
      if (Trenner < 3) then Continue;

      Schluessel := UpperCase(Trim(Copy(Zeile, 2, Trenner - 2)));
      Wert := Trim(Copy(Zeile, Trenner + 1, Length(Zeile)));

      if      (Schluessel = 'ARTIST')   then Header.Artist   := Wert
      else if (Schluessel = 'TITLE')    then Header.Title    := Wert
      else if (Schluessel = 'EDITION')  then Header.Edition  := Wert
      else if (Schluessel = 'GENRE')    then Header.Genre    := Wert
      else if (Schluessel = 'LANGUAGE') then Header.Language := Wert
      else if (Schluessel = 'YEAR')     then Header.Year     := LiesJahr(Wert)
      // AUDIO ist die heutige Schreibweise, MP3 die aeltere. MP3 darf AUDIO
      // nicht ueberschreiben, wenn beide dastehen.
      else if (Schluessel = 'AUDIO')    then TonName   := Wert
      else if (Schluessel = 'VIDEO')    then VideoName := Wert
      else if (Schluessel = 'BACKGROUND') then BildName := Wert
      // VIDEOGAP steht mal mit Punkt, mal mit Komma - wie alle Kommazahlen
      // im Format.
      else if (Schluessel = 'VIDEOGAP') then
        Header.VideoGap := StrToFloatDef(
          StringReplace(Wert, ',', '.', [rfReplaceAll]), 0, FormatSettings)
      else if (Schluessel = 'MP3') and (TonName = '') then TonName := Wert;
    end;
  finally
    {$I-}
    CloseFile(Datei);
    {$I+}
    if (IOResult <> 0) then ;   // beim Schliessen ist ein Fehler egal
  end;

  Ordner := ExtractFilePath(FileName);
  Header.AudioPath := Daneben(TonName);
  Header.VideoPath := Daneben(VideoName);
  Header.BackgPath := Daneben(BildName);

  Result := (Header.Title <> '') or (Header.Artist <> '');
end;

end.
