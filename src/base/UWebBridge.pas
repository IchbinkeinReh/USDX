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
    VideoPath: UTF8String;
    BackgPath: UTF8String;
  end;

  // Welche Datei eines Liedes gemeint ist.
  TWebFileKind = (wfkTxt, wfkAudio, wfkVideo, wfkBackground);

  // Vorbereitete Suchtexte zu einem Lied: kleingeschrieben und ins
  // ASCII-Alphabet umgeschrieben, damit "uber" auch "Über" findet.
  //
  // Bewusst NEBEN der Liederliste und nicht in TWebSong: Das Lied ist, was
  // die Weboberflaeche zu sehen bekommt, dies hier ist ein Suchregister und
  // geht sie nichts an. So bleiben auch die Kopien klein, die FindSongs
  // zurueckgibt.
  TSuchIndex = record
    Alle, Title, Artist, Edition, Genre, Language, Year: UTF8String;
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
      fSuch:     array of TSuchIndex;
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
      function  SongPath(Index: integer; Art: TWebFileKind;
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

// Schreibt einen Text so um, wie die Suche ihn vergleicht.
function SuchForm(const Text: UTF8String): UTF8String;
begin
  Result := LowerCase(TransliterateToASCII(Text));
end;

procedure TWebBridge.PublishSongs(const Songs: TWebSongArray);
var
  I: integer;
  Jahr: UTF8String;
begin
  fLock.Acquire;
  try
    // Elementweise kopieren statt die Referenz zu uebernehmen: Sonst teilten
    // sich Spiel und Web dasselbe Array, und der Sinn der Abschrift waere
    // dahin.
    SetLength(fSongs, Length(Songs));
    // Das Suchregister wird hier mit aufgebaut, nicht bei jeder Anfrage.
    //
    // Vorher schrieb FindSongs jeden Text je Anfrage neu klein und um. Bei
    // gut zwanzig Liedern faellt das nicht auf; bei ueber neuntausend kostet
    // eine Suche, die wenig trifft, dreiviertel Sekunden - und beim Tippen
    // merkt man jede davon.
    SetLength(fSuch, Length(Songs));
    for I := 0 to High(Songs) do
    begin
      fSongs[I] := Songs[I];

      Jahr := IntToStr(Songs[I].Year);
      fSuch[I].Title    := SuchForm(Songs[I].Title);
      fSuch[I].Artist   := SuchForm(Songs[I].Artist);
      fSuch[I].Edition  := SuchForm(Songs[I].Edition);
      fSuch[I].Genre    := SuchForm(Songs[I].Genre);
      fSuch[I].Language := SuchForm(Songs[I].Language);
      fSuch[I].Year     := Jahr;
      // Der gemeinsame Heuhaufen aus den schon umgeschriebenen Teilen -
      // nicht noch einmal umschreiben, das Ergebnis waere dasselbe.
      fSuch[I].Alle := fSuch[I].Artist + ' ' + fSuch[I].Title + ' ' +
                       fSuch[I].Edition + ' ' + fSuch[I].Genre + ' ' +
                       fSuch[I].Language + ' ' + Jahr;
    end;
    Inc(fStand);
  finally
    fLock.Release;
  end;
end;

function TWebBridge.SongPath(Index: integer; Art: TWebFileKind;
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
      case Art of
        wfkAudio:      Path := fSongs[Index].AudioPath;
        wfkVideo:      Path := fSongs[Index].VideoPath;
        wfkBackground: Path := fSongs[Index].BackgPath;
      else
        Path := fSongs[Index].TxtPath;
      end;
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
        // Fertig vorbereitet aus dem Register, siehe PublishSongs.
        case Filter of
          fltTitle:    Heuhaufen := fSuch[I].Title;
          fltArtist:   Heuhaufen := fSuch[I].Artist;
          fltEdition:  Heuhaufen := fSuch[I].Edition;
          fltGenre:    Heuhaufen := fSuch[I].Genre;
          fltLanguage: Heuhaufen := fSuch[I].Language;
          fltYear:     Heuhaufen := fSuch[I].Year;
          else         Heuhaufen := fSuch[I].Alle;
        end;

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
