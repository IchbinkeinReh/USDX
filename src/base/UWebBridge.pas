unit UWebBridge;

(*
 * Uebergabestelle zwischen Spiel und Weboberflaeche.
 *
 * Der Webserver laeuft in einem eigenen Thread und darf die Datenstrukturen
 * des Spiels NICHT anfassen: CatSongs.Song wird beim Einlesen, Sortieren und
 * Filtern staendig veraendert, und ein Zugriff von aussen waehrenddessen
 * liest halbfertige Zustaende oder stuerzt ab.
 *
 * Stattdessen zwei Richtungen ueber eine Sperre:
 *
 *   Spiel  -> Web:  Der Spielthread veroeffentlicht eine Abschrift der
 *                   Liederliste. Der Webthread sucht nur darin.
 *   Web    -> Spiel: Der Webthread legt Befehle in eine Schlange. Der
 *                   Spielthread holt sie in seiner Schleife ab und fuehrt
 *                   sie dort aus, wo es sicher ist.
 *
 * Nichts davon haengt an SDL, Fenster oder Ton - deshalb laesst sich diese
 * Unit ohne laufendes Spiel pruefen, und genau hier steckt die Logik, bei
 * der Fehler teuer waeren.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  UUnicodeUtils,
  USongFilter,
  USongSearch;

type
  // Ein Lied, so wie die Weboberflaeche es braucht - eine Abschrift, kein
  // Verweis auf das Original.
  TWebSong = record
    Index:    integer;      // Platz in CatSongs.Song, fuer spaetere Befehle
    Artist:   UTF8String;
    Title:    UTF8String;
    Edition:  UTF8String;
    Genre:    UTF8String;
    Language: UTF8String;
    Year:     integer;
    Duet:     boolean;      // hat zwei Stimmen (P1/P2)
    // Dateien fuer die Weboberflaeche. Der Browser bekommt sie NIE zu sehen -
    // er schickt nur den Index, und der Server schlaegt den Pfad hier nach.
    // Damit ist ein Ausbruch aus dem Liedordner ueber die URL ausgeschlossen.
    TxtPath:   UTF8String;
    AudioPath: UTF8String;
  end;
  TWebSongArray = array of TWebSong;

  TWebCommandKind = (wckNone, wckStart);

  TWebCommand = record
    Kind:      TWebCommandKind;
    SongIndex: integer;
  end;

  TWebBridge = class
    private
      fLock:     TCriticalSection;
      fSongs:    TWebSongArray;
      fCommands: array of TWebCommand;
      fStand:    integer;   // steigt bei jeder Veroeffentlichung
    public
      constructor Create;
      destructor Destroy; override;

      // --- vom Spielthread ---
      procedure PublishSongs(const Songs: TWebSongArray);
      // Holt den naechsten Befehl. false, wenn keiner wartet.
      function  NextCommand(out Cmd: TWebCommand): boolean;

      // --- vom Webthread ---
      // Sucht in der Abschrift. Query wird wie im Spiel ausgewertet, also
      // mit AND, OR, Klammern, Ausschluss und Jahresbereichen.
      function  FindSongs(const Query: UTF8String; Filter: TSongFilter;
                          Max: integer): TWebSongArray;
      procedure PostCommand(Kind: TWebCommandKind; SongIndex: integer);

      // Schlaegt den Dateipfad zu einem Index nach. false, wenn es den Index
      // nicht gibt oder das Lied keine solche Datei hat.
      function  SongPath(Index: integer; Audio: boolean;
                         out Path: UTF8String): boolean;

      function  SongCount: integer;
      function  Stand: integer;
  end;

implementation

const
  // Mehr Befehle koennen nicht auflaufen, als der Spielthread zwischen zwei
  // Bildern abholt. Die Grenze schuetzt davor, dass ein haengendes Spiel den
  // Speicher volllaufen laesst.
  MAX_BEFEHLE = 64;

constructor TWebBridge.Create;
begin
  inherited Create;
  fLock := TCriticalSection.Create;
  fStand := 0;
end;

destructor TWebBridge.Destroy;
begin
  fLock.Free;
  inherited;
end;

procedure TWebBridge.PublishSongs(const Songs: TWebSongArray);
var
  I: integer;
begin
  fLock.Acquire;
  try
    // Elementweise kopieren statt die Referenz zu uebernehmen: Sonst teilten
    // sich Spiel und Web dasselbe Array, und der Sinn der Abschrift waere
    // dahin.
    SetLength(fSongs, Length(Songs));
    for I := 0 to High(Songs) do
      fSongs[I] := Songs[I];
    Inc(fStand);
  finally
    fLock.Release;
  end;
end;

function TWebBridge.SongPath(Index: integer; Audio: boolean;
                             out Path: UTF8String): boolean;
begin
  Path := '';
  fLock.Acquire;
  try
    // Der Index zaehlt in der Abschrift, nicht in CatSongs: Beides kann
    // auseinanderlaufen, wenn waehrenddessen neu eingelesen wurde.
    Result := (Index >= 0) and (Index <= High(fSongs));
    if Result then
    begin
      if Audio then
        Path := fSongs[Index].AudioPath
      else
        Path := fSongs[Index].TxtPath;
      Result := Path <> '';
    end;
  finally
    fLock.Release;
  end;
end;

function TWebBridge.SongCount: integer;
begin
  fLock.Acquire;
  try
    Result := Length(fSongs);
  finally
    fLock.Release;
  end;
end;

function TWebBridge.Stand: integer;
begin
  fLock.Acquire;
  try
    Result := fStand;
  finally
    fLock.Release;
  end;
end;

function TWebBridge.FindSongs(const Query: UTF8String; Filter: TSongFilter;
                              Max: integer): TWebSongArray;
var
  Baum: PSearchNode;
  I, Anzahl: integer;
  Heuhaufen: UTF8String;
begin
  SetLength(Result, 0);
  if (Max <= 0) then
    Exit;

  // Ausdruck EINMAL zerlegen, nicht je Lied - genau wie im Spiel.
  Baum := BuildSearchTree(Query);
  try
    fLock.Acquire;
    try
      Anzahl := 0;
      SetLength(Result, Length(fSongs));
      for I := 0 to High(fSongs) do
      begin
        case Filter of
          fltTitle:    Heuhaufen := fSongs[I].Title;
          fltArtist:   Heuhaufen := fSongs[I].Artist;
          fltEdition:  Heuhaufen := fSongs[I].Edition;
          fltGenre:    Heuhaufen := fSongs[I].Genre;
          fltLanguage: Heuhaufen := fSongs[I].Language;
          fltYear:     Heuhaufen := IntToStr(fSongs[I].Year);
          else
            Heuhaufen := fSongs[I].Artist + ' ' + fSongs[I].Title + ' ' +
                         fSongs[I].Edition + ' ' + fSongs[I].Genre + ' ' +
                         fSongs[I].Language + ' ' + IntToStr(fSongs[I].Year);
        end;
        // Kleinschreiben und Umschreiben wie in der Suche des Spiels, sonst
        // faende "uber" kein "Über".
        Heuhaufen := LowerCase(TransliterateToASCII(Heuhaufen));

        if EvalSearchNode(Baum, Heuhaufen, fSongs[I].Year) then
        begin
          Result[Anzahl] := fSongs[I];
          Inc(Anzahl);
          if (Anzahl >= Max) then
            Break;
        end;
      end;
      SetLength(Result, Anzahl);
    finally
      fLock.Release;
    end;
  finally
    FreeSearchNode(Baum);
  end;
end;

procedure TWebBridge.PostCommand(Kind: TWebCommandKind; SongIndex: integer);
begin
  fLock.Acquire;
  try
    if (Length(fCommands) >= MAX_BEFEHLE) then
      Exit;   // stumm verwerfen - lieber ein verlorener Tastendruck als Wachstum ohne Ende
    SetLength(fCommands, Length(fCommands) + 1);
    fCommands[High(fCommands)].Kind := Kind;
    fCommands[High(fCommands)].SongIndex := SongIndex;
  finally
    fLock.Release;
  end;
end;

function TWebBridge.NextCommand(out Cmd: TWebCommand): boolean;
var
  I: integer;
begin
  Result := false;
  Cmd.Kind := wckNone;
  Cmd.SongIndex := -1;

  fLock.Acquire;
  try
    if (Length(fCommands) = 0) then
      Exit;
    Cmd := fCommands[0];
    for I := 0 to High(fCommands) - 1 do
      fCommands[I] := fCommands[I + 1];
    SetLength(fCommands, Length(fCommands) - 1);
    Result := true;
  finally
    fLock.Release;
  end;
end;

end.
