unit UWebVorschau;

(*
 * Vorschau-Schnipsel fuer die Liedauswahl im Browser.
 *
 * Warum eine eigene Datei und nicht ein Stueck aus dem Lied: Die Sammlung
 * hier besteht praktisch vollstaendig aus .m4a, und ein MP4 laesst sich
 * NICHT byteweise schneiden. Ein Stueck aus der Mitte hat weder ftyp noch
 * moov, und der Browser lehnt es rundheraus ab (nachgemessen:
 * MEDIA_ERR_SRC_NOT_SUPPORTED). Auch vorne abzuschneiden hilft nicht, denn
 * ffmpeg legt moov standardmaessig HINTER mdat.
 *
 * Bei MP3 ginge es - ein Rahmen findet sich ueberall wieder -, aber zwei
 * Verfahren nebeneinander waeren zwei Fehlerquellen. Deshalb fuer alle
 * Formate dasselbe: ffmpeg schneidet einmal einen fertigen Schnipsel, und
 * ausgeliefert wird danach eine ganz gewoehnliche Datei.
 *
 * Damit ist die Laengenbegrenzung auch keine Zusage mehr, auf die man
 * vertrauen muss: Was nicht im Schnipsel steht, kann niemand abrufen.
 *
 * Die Schnipsel liegen NEBEN der Tondatei. Der Liederordner liegt hier auf
 * einem eigenen Dateisystem mit Platz, das Wurzeldateisystem nicht. Steht
 * der Ordner nur lesbar (ProtectSystem/ReadOnlyPaths in der Dienstdatei),
 * scheitert das Erzeugen - dann gibt es eben keine Vorschau, und der Rest
 * laeuft weiter.
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
  // Laenge eines Schnipsels. Kuerzer als die Vorgabe im Spiel, weil das mal
  // dreissigtausend Lieder ist: je Sekunde rund 12 kB, und daraus werden
  // schnell Gigabytes.
  VORSCHAU_SEKUNDEN = 30;

  VORSCHAU_BITRATE  = '96k';
  VORSCHAU_KANAELE  = '1';
  VORSCHAU_RATE     = '44100';

  // Angehaengt an den Namen der Tondatei. Die Endung bleibt .mp3, damit der
  // Browser nicht raten muss - und .txt wird nicht beruehrt, also findet der
  // Liedsucher dadurch auch kein zweites Lied.
  VORSCHAU_ENDUNG = '.vorschau.mp3';

  // So viel muss auf dem Dateisystem frei BLEIBEN. Der Liederordner liegt
  // hier auf derselben Platte wie anderes; eine volle Platte reisst mehr
  // mit als nur die Vorschau.
  VORSCHAU_MIN_FREI_MB = 1024;

type
  // Wie es einem Lied beim Bauen ergangen ist - fuer den Fortschritt.
  TVorschauStand = record
    Gesamt:    integer;
    Gebaut:    integer;   // neu erzeugt
    Vorhanden: integer;   // war schon da
    Fehler:    integer;
    Fertig:    boolean;
    Abbruch:   UTF8String;  // <> '' : abgebrochen, hier steht warum
  end;

// Pfad des Schnipsels zu einer Tondatei. Leer, wenn kein Ton bekannt ist.
function VorschauPfad(const AudioPfad: UTF8String): UTF8String;

// Ab welcher Sekunde der Schnipsel beginnt.
//
// Dieselbe Rechnung wie previewRange() in web/js/song.js und
// TSong.GetPreviewRange in USong.pas - nachgebaut, weil sie hier gebraucht
// wird, bevor irgendein Browser die Datei gesehen hat. Alle Angaben in
// Sekunden; Finish ist bereits umgerechnet (#END steht in Millisekunden).
function VorschauStelle(PreviewStart, Start, Finish, Dauer: double): double;

// Dauer einer Tondatei in Sekunden, ueber ffprobe. 0 = unbekannt.
function TonDauer(const AudioPfad: UTF8String): double;

// Schneidet den Schnipsel. False, wenn ffmpeg nicht mitspielt.
function ErzeugeVorschau(const AudioPfad, ZielPfad: UTF8String;
                         AbSekunde: double): boolean;

// Liegt ein brauchbarer Schnipsel schon da? Aelter als die Tondatei zaehlt
// als nicht brauchbar - sonst bliebe nach dem Austauschen eines Liedes die
// alte Vorschau liegen.
function VorschauAktuell(const AudioPfad: UTF8String): boolean;

// Freier Platz auf dem Dateisystem, in dem Pfad liegt. -1 = unbekannt.
function FreiMB(const Pfad: UTF8String): int64;

// Sind ffmpeg und ffprobe aufrufbar?
function FfmpegDa: boolean;

function DateiGroesse(const Pfad: UTF8String): int64;

type
  // Was zum Schneiden eines Liedes gebraucht wird. Bewusst ein eigener,
  // kleiner Satz Daten statt TWebSong: Diese Einheit soll nichts von der
  // Bruecke wissen muessen.
  TVorschauAuftrag = record
    AudioPfad: UTF8String;
    PreviewStart, Start, Finish: double;
  end;
  TVorschauAuftragArray = array of TVorschauAuftrag;

  // Baut die fehlenden Schnipsel, im Hintergrund.
  //
  // Im Hintergrund, weil es beim ersten Lauf ueber eine grosse Sammlung
  // Stunden dauert - der Server muss derweil ansprechbar bleiben, und die
  // Vorschauen tauchen nach und nach auf. Beim naechsten Start ist fast
  // alles schon da und der Durchlauf dauert Sekunden.
  TVorschauBauer = class(TThread)
    private
      fAuftraege: TVorschauAuftragArray;
      fLock: TCriticalSection;
      fStand: TVorschauStand;
      procedure Melde(const Text: UTF8String);
    protected
      procedure Execute; override;
    public
      constructor Create(const Auftraege: TVorschauAuftragArray);
      destructor Destroy; override;
      function Stand: TVorschauStand;
  end;

var
  // Wohin der Bauer meldet - dieselbe Bauart wie WebLogHandler in
  // UWebServer, damit diese Einheit nicht an ULog und damit an SDL haengt.
  VorschauLogHandler: procedure(const Nachricht: UTF8String) = nil;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  Unix,          // fpStatFS - TStatFS selbst steht in BaseUnix
  {$ENDIF}
  process;

function DateiGroesse(const Pfad: UTF8String): int64;
var
  S: TSearchRec;
begin
  Result := -1;
  if (FindFirst(Pfad, faAnyFile, S) = 0) then
  begin
    Result := S.Size;
    FindClose(S);
  end;
end;

function VorschauPfad(const AudioPfad: UTF8String): UTF8String;
begin
  Result := '';
  if (AudioPfad = '') then Exit;
  // An den GANZEN Namen angehaengt, nicht die Endung ersetzt: Sonst
  // kollidierten "Lied.mp3" und "Lied.m4a" im selben Ordner auf derselben
  // Vorschau.
  Result := AudioPfad + VORSCHAU_ENDUNG;
end;

function VorschauStelle(PreviewStart, Start, Finish, Dauer: double): double;
var
  EffStart, EffEnde, EffLaenge, Versatz: double;
begin
  Result := 0;
  if not (Dauer > 0) then Exit;

  EffStart := Start;
  if (EffStart < 0) then EffStart := 0;
  if (EffStart > Dauer) then EffStart := Dauer;

  if (Finish > 0) then
  begin
    EffEnde := Finish;
    if (EffEnde < 0) then EffEnde := 0;
    if (EffEnde > Dauer) then EffEnde := Dauer;
  end
  else
    EffEnde := Dauer;

  // Unsinnige Angaben (Ende vor Anfang) verwerfen und das ganze Lied nehmen.
  if (EffEnde <= EffStart) then
  begin
    EffStart := 0;
    EffEnde := Dauer;
  end;

  // Ein eigener #PREVIEWSTART gilt, sofern er ueberhaupt im Lied liegt.
  if (PreviewStart > 0) and (PreviewStart >= EffStart) and
     (PreviewStart < EffEnde) then
  begin
    Result := PreviewStart;
    Exit;
  end;

  // Sonst ein Viertel hinein. Die Sonderregel darueber stammt aus dem Spiel
  // und sieht falsch aus, ist aber so gewollt: Ab zwei Minuten Versatz wird
  // NICHT gedeckelt, sondern auf eine Minute zurueckgesetzt.
  EffLaenge := EffEnde - EffStart;
  Versatz := EffLaenge / 4;
  if (Versatz > 120) then Versatz := 60;
  Result := EffStart + Versatz;
end;

// Ruft ein Programm auf und gibt seine Ausgabe zurueck.
//
// Ueber TProcess mit getrennten Parametern, NICHT ueber eine Befehlszeile:
// In dieser Sammlung stecken Anfuehrungszeichen, Apostrophe, Klammern und
// Dollarzeichen in Dateinamen. Ginge das durch eine Shell, waere das eine
// Befehlseinschleusung mit Ansage.
function Rufe(const Programm: UTF8String; const Args: array of UTF8String;
              out Ausgabe: UTF8String; out Status: integer): boolean;
var
  P: TProcess;
  Zeilen: TStringList;
  I: integer;
begin
  Result := False;
  Ausgabe := '';
  Status := -1;
  P := TProcess.Create(nil);
  try
    P.Executable := Programm;
    for I := Low(Args) to High(Args) do
      P.Parameters.Add(Args[I]);
    P.Options := [poWaitOnExit, poUsePipes, poStderrToOutPut];
    P.ShowWindow := swoHIDE;
    try
      P.Execute;
    except
      // Programm nicht da - das ist kein Absturzgrund.
      Exit;
    end;
    Zeilen := TStringList.Create;
    try
      Zeilen.LoadFromStream(P.Output);
      Ausgabe := Trim(Zeilen.Text);
    finally
      Zeilen.Free;
    end;
    Status := P.ExitStatus;
    Result := True;
  finally
    P.Free;
  end;
end;

function FfmpegDa: boolean;
var
  Ausgabe: UTF8String;
  Status: integer;
begin
  Result := Rufe('ffmpeg', ['-version'], Ausgabe, Status) and (Status = 0) and
            Rufe('ffprobe', ['-version'], Ausgabe, Status) and (Status = 0);
end;

function TonDauer(const AudioPfad: UTF8String): double;
var
  Ausgabe: UTF8String;
  Status: integer;
  Alt: TFormatSettings;
begin
  Result := 0;
  if not FileExists(AudioPfad) then Exit;
  if not Rufe('ffprobe',
              ['-v', 'error',
               '-show_entries', 'format=duration',
               '-of', 'default=nw=1:nk=1',
               AudioPfad], Ausgabe, Status) then Exit;
  if (Status <> 0) then Exit;
  // ffprobe schreibt immer mit Punkt, unabhaengig von der Spracheinstellung
  // des Rechners - deshalb hier ausdruecklich mit Punkt lesen und nicht mit
  // dem, was gerade eingestellt ist.
  Alt := FormatSettings;
  Alt.DecimalSeparator := '.';
  Result := StrToFloatDef(Trim(Ausgabe), 0, Alt);
  if (Result < 0) then Result := 0;
end;

function ErzeugeVorschau(const AudioPfad, ZielPfad: UTF8String;
                         AbSekunde: double): boolean;
var
  Ausgabe, Teil, Stelle: UTF8String;
  Status: integer;
  Alt: TFormatSettings;
begin
  Result := False;
  if (AudioPfad = '') or (ZielPfad = '') then Exit;
  if not FileExists(AudioPfad) then Exit;
  if (AbSekunde < 0) then AbSekunde := 0;

  Alt := FormatSettings;
  Alt.DecimalSeparator := '.';
  Stelle := FormatFloat('0.###', AbSekunde, Alt);

  // Erst in eine Nebendatei, dann umbenennen. Bricht der Lauf mittendrin ab
  // (Strom weg, Platte voll), liegt sonst ein halber Schnipsel da, den der
  // naechste Start fuer fertig haelt.
  Teil := ZielPfad + '.teil';
  DeleteFile(Teil);

  if not Rufe('ffmpeg',
              ['-v', 'error',
               '-y',
               // -ss VOR -i: schnelles Springen ueber den Index, statt die
               // Datei bis dorthin zu dekodieren. Bei dreissigtausend
               // Liedern ist das der Unterschied zwischen Stunden und Tagen.
               '-ss', Stelle,
               '-t', IntToStr(VORSCHAU_SEKUNDEN),
               '-i', AudioPfad,
               // Kein Bild: .m4a tragen oft ein Titelbild, .mp4 ein ganzes
               // Video. Beides gehoert nicht in einen Tonschnipsel.
               '-vn',
               '-ac', VORSCHAU_KANAELE,
               '-ar', VORSCHAU_RATE,
               '-codec:a', 'libmp3lame',
               '-b:a', VORSCHAU_BITRATE,
               // Format ausdruecklich nennen: Die Nebendatei heisst auf
               // .teil, und daraus kann ffmpeg es nicht raten ("Unable to
               // find a suitable output format"). Genau daran ist es zuerst
               // gescheitert.
               '-f', 'mp3',
               Teil], Ausgabe, Status) then Exit;

  if (Status <> 0) or not FileExists(Teil) then
  begin
    DeleteFile(Teil);
    Exit;
  end;

  // Ein leerer Schnipsel entsteht, wenn die Stelle hinter dem Ende lag.
  // Den behalten wir nicht - sonst spielte die Auswahl lautlos.
  if (DateiGroesse(Teil) < 1024) then
  begin
    DeleteFile(Teil);
    Exit;
  end;

  DeleteFile(ZielPfad);
  Result := RenameFile(Teil, ZielPfad);
  if not Result then
    DeleteFile(Teil);
end;

function VorschauAktuell(const AudioPfad: UTF8String): boolean;
var
  Ziel: UTF8String;
  AlterTon, AlterSchnipsel: longint;
begin
  Result := False;
  Ziel := VorschauPfad(AudioPfad);
  if (Ziel = '') or not FileExists(Ziel) then Exit;
  if not FileExists(AudioPfad) then Exit;

  AlterTon := FileAge(AudioPfad);
  AlterSchnipsel := FileAge(Ziel);
  if (AlterTon < 0) or (AlterSchnipsel < 0) then
  begin
    // Alter nicht feststellbar: Dann gilt der vorhandene Schnipsel. Lieber
    // eine vielleicht alte Vorschau als bei jedem Start alles neu.
    Result := True;
    Exit;
  end;
  Result := AlterSchnipsel >= AlterTon;
end;

function FreiMB(const Pfad: UTF8String): int64;
{$IFDEF UNIX}
var
  Info: TStatFS;
  Ordner: UTF8String;
begin
  Result := -1;
  Ordner := ExtractFilePath(Pfad);
  if (Ordner = '') then Ordner := '.';
  if (fpStatFS(PChar(Ordner), @Info) <> 0) then Exit;
  Result := (int64(Info.bavail) * int64(Info.bsize)) div (1024 * 1024);
end;
{$ELSE}
begin
  Result := DiskFree(0) div (1024 * 1024);
end;
{$ENDIF}

// --- Der Bauer ------------------------------------------------------------

constructor TVorschauBauer.Create(const Auftraege: TVorschauAuftragArray);
begin
  fLock := TCriticalSection.Create;
  fAuftraege := Copy(Auftraege, 0, Length(Auftraege));
  FillChar(fStand, SizeOf(fStand), 0);
  fStand.Gesamt := Length(fAuftraege);
  fStand.Abbruch := '';
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TVorschauBauer.Destroy;
begin
  SetLength(fAuftraege, 0);
  fLock.Free;
  inherited;
end;

procedure TVorschauBauer.Melde(const Text: UTF8String);
begin
  if Assigned(VorschauLogHandler) then
    VorschauLogHandler(Text);
end;

function TVorschauBauer.Stand: TVorschauStand;
begin
  fLock.Acquire;
  try
    Result := fStand;
  finally
    fLock.Release;
  end;
end;

procedure TVorschauBauer.Execute;
var
  I: integer;
  Ziel: UTF8String;
  Dauer, Stelle: double;
  Frei: int64;
  Gebaut, Vorhanden, Fehler: integer;
  Angefangen: TDateTime;
begin
  Gebaut := 0;
  Vorhanden := 0;
  Fehler := 0;
  Angefangen := Now;

  if (Length(fAuftraege) = 0) then
  begin
    fLock.Acquire;
    try fStand.Fertig := True; finally fLock.Release; end;
    Exit;
  end;

  if not FfmpegDa then
  begin
    fLock.Acquire;
    try
      fStand.Fertig := True;
      fStand.Abbruch := 'ffmpeg/ffprobe nicht gefunden';
    finally fLock.Release; end;
    Melde('Vorschau: ffmpeg oder ffprobe nicht gefunden - keine Vorschauen');
    Exit;
  end;

  Melde(Format('Vorschau: %d Lieder werden geprueft', [Length(fAuftraege)]));

  for I := 0 to High(fAuftraege) do
  begin
    if Terminated then Break;

    Ziel := VorschauPfad(fAuftraege[I].AudioPfad);
    if (Ziel = '') then
    begin
      Inc(Fehler);
      Continue;
    end;

    if VorschauAktuell(fAuftraege[I].AudioPfad) then
    begin
      Inc(Vorhanden);
    end
    else
    begin
      // Vor JEDEM Schnitt nachsehen, nicht nur einmal am Anfang: Auf dieser
      // Platte liegt mehr als die Lieder, und ein anderer Dienst kann
      // waehrenddessen Platz belegen. Eine volle Platte reisst alles mit.
      Frei := FreiMB(Ziel);
      if (Frei >= 0) and (Frei < VORSCHAU_MIN_FREI_MB) then
      begin
        fLock.Acquire;
        try
          fStand.Abbruch := Format('zu wenig Platz (%d MB frei)', [Frei]);
        finally fLock.Release; end;
        Melde(Format('Vorschau: abgebrochen, nur noch %d MB frei', [Frei]));
        Break;
      end;

      Dauer := TonDauer(fAuftraege[I].AudioPfad);
      Stelle := VorschauStelle(fAuftraege[I].PreviewStart,
                               fAuftraege[I].Start,
                               fAuftraege[I].Finish,
                               Dauer);
      if ErzeugeVorschau(fAuftraege[I].AudioPfad, Ziel, Stelle) then
        Inc(Gebaut)
      else
        Inc(Fehler);
    end;

    fLock.Acquire;
    try
      fStand.Gebaut := Gebaut;
      fStand.Vorhanden := Vorhanden;
      fStand.Fehler := Fehler;
    finally fLock.Release; end;

    // Alle fuenfhundert ein Lebenszeichen. Bei dreissigtausend Liedern
    // laeuft das stundenlang, und ohne Meldung sieht es aus, als haenge es.
    if ((I + 1) mod 500 = 0) then
      Melde(Format('Vorschau: %d von %d (%d neu, %d schon da, %d Fehler)',
                   [I + 1, Length(fAuftraege), Gebaut, Vorhanden, Fehler]));
  end;

  fLock.Acquire;
  try
    fStand.Gebaut := Gebaut;
    fStand.Vorhanden := Vorhanden;
    fStand.Fehler := Fehler;
    fStand.Fertig := True;
  finally fLock.Release; end;

  Melde(Format('Vorschau: fertig - %d neu, %d schon da, %d Fehler, %.0f s',
               [Gebaut, Vorhanden, Fehler, (Now - Angefangen) * 86400]));
end;

end.
