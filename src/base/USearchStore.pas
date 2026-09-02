unit USearchStore;

(*
 * Gespeicherte Suchen: Suchbegriff und Suchmodus unter einem Namen ablegen
 * und spaeter wieder laden.
 *
 * Die Ablage ist eine schlichte Textdatei, eine Zeile je Suche:
 *
 *     <Modus><TAB><Suchbegriff>
 *
 * Tabulator als Trenner, weil er in einem Suchbegriff nicht vorkommen kann -
 * die Eingabe im Spiel laesst ihn gar nicht zu. Ein Gleichheitszeichen oder
 * Doppelpunkt waere in "AC/DC: Back in Black" dagegen ein Problem.
 *
 * Der Modus wird als Name geschrieben ("title"), nicht als Zahl: Wenn
 * TSongFilter spaeter einen Wert dazubekommt, verschieben sich sonst alle
 * gespeicherten Suchen lautlos auf einen anderen Modus.
 *
 * Bewusst ohne Abhaengigkeit auf Dateipfade oder Spielzustand: So laesst sich
 * die Ablage ohne Fenster, Ton und geladene Lieder pruefen.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  USongFilter;

type
  TSavedSearch = record
    Text:   UTF8String;   // der Suchbegriff
    Filter: TSongFilter;  // der Suchmodus
  end;

  TSearchStore = class
    private
      fEntries: array of TSavedSearch;
      function GetCount: integer;
      function GetEntry(Index: integer): TSavedSearch;
    public
      // Nimmt eine Suche auf. Eine bereits vorhandene, gleiche Suche wird
      // NICHT doppelt abgelegt - sonst fuellt sich die Liste mit
      // Wiederholungen, wenn jemand mehrfach speichert.
      // Rueckgabe: true, wenn ein neuer Eintrag entstanden ist.
      function Add(const AText: UTF8String; AFilter: TSongFilter): boolean;
      procedure Delete(Index: integer);
      procedure Clear;

      procedure LoadFromStrings(Lines: TStrings);
      procedure SaveToStrings(Lines: TStrings);

      // Anzeigetext, z.B. 'Titel: abba OR queen'
      function Caption(Index: integer): UTF8String;

      property Count: integer read GetCount;
      property Entries[Index: integer]: TSavedSearch read GetEntry; default;
  end;

// Modusnamen fuer Datei und Anzeige.
function FilterToName(Filter: TSongFilter): UTF8String;
function NameToFilter(const Name: UTF8String; out Filter: TSongFilter): boolean;
function FilterCaption(Filter: TSongFilter): UTF8String;

implementation

const
  // Reihenfolge muss zu TSongFilter passen; geprueft von den Tests.
  FilterNames: array[TSongFilter] of UTF8String = (
    'all', 'title', 'artist', 'language', 'edition', 'genre', 'year',
    'creator', 'tags');
  FilterCaptions: array[TSongFilter] of UTF8String = (
    'Alle', 'Titel', 'Interpret', 'Sprache', 'Edition', 'Genre', 'Jahr',
    'Ersteller', 'Schlagworte');

function FilterToName(Filter: TSongFilter): UTF8String;
begin
  Result := FilterNames[Filter];
end;

function NameToFilter(const Name: UTF8String; out Filter: TSongFilter): boolean;
var
  F: TSongFilter;
  Lower: UTF8String;
begin
  Result := false;
  Lower := LowerCase(Trim(Name));
  for F := Low(TSongFilter) to High(TSongFilter) do
    if (FilterNames[F] = Lower) then
    begin
      Filter := F;
      Result := true;
      Exit;
    end;
end;

function FilterCaption(Filter: TSongFilter): UTF8String;
begin
  Result := FilterCaptions[Filter];
end;

{ TSearchStore }

function TSearchStore.GetCount: integer;
begin
  Result := Length(fEntries);
end;

function TSearchStore.GetEntry(Index: integer): TSavedSearch;
begin
  Result := fEntries[Index];
end;

function TSearchStore.Add(const AText: UTF8String; AFilter: TSongFilter): boolean;
var
  I: integer;
  Trimmed: UTF8String;
begin
  Result := false;
  Trimmed := Trim(AText);
  // Eine leere Suche zu speichern ergibt keinen Sinn - sie laedt nichts.
  if (Trimmed = '') then
    Exit;

  for I := 0 to High(fEntries) do
    if (fEntries[I].Filter = AFilter) and (fEntries[I].Text = Trimmed) then
      Exit;

  SetLength(fEntries, Length(fEntries) + 1);
  fEntries[High(fEntries)].Text := Trimmed;
  fEntries[High(fEntries)].Filter := AFilter;
  Result := true;
end;

procedure TSearchStore.Delete(Index: integer);
var
  I: integer;
begin
  if (Index < 0) or (Index > High(fEntries)) then
    Exit;
  for I := Index to High(fEntries) - 1 do
    fEntries[I] := fEntries[I + 1];
  SetLength(fEntries, Length(fEntries) - 1);
end;

procedure TSearchStore.Clear;
begin
  SetLength(fEntries, 0);
end;

procedure TSearchStore.LoadFromStrings(Lines: TStrings);
var
  I, TabPos: integer;
  Line, NamePart, TextPart: UTF8String;
  Filter: TSongFilter;
begin
  Clear;
  for I := 0 to Lines.Count - 1 do
  begin
    Line := Lines[I];
    if (Trim(Line) = '') or (Copy(Line, 1, 1) = '#') then
      Continue;
    TabPos := Pos(#9, Line);
    if (TabPos < 2) then
      Continue;
    NamePart := Copy(Line, 1, TabPos - 1);
    TextPart := Copy(Line, TabPos + 1, Length(Line) - TabPos);
    // Unbekannter Modus: Zeile ueberspringen statt auf "Alle" zu raten -
    // eine Suche im falschen Modus liefert stillschweigend falsche Treffer.
    if not NameToFilter(NamePart, Filter) then
      Continue;
    Add(TextPart, Filter);
  end;
end;

procedure TSearchStore.SaveToStrings(Lines: TStrings);
var
  I: integer;
begin
  Lines.Clear;
  Lines.Add('# UltraStar Deluxe - gespeicherte Suchen');
  Lines.Add('# Je Zeile: Modus <TAB> Suchbegriff');
  for I := 0 to High(fEntries) do
    Lines.Add(FilterToName(fEntries[I].Filter) + #9 + fEntries[I].Text);
end;

function TSearchStore.Caption(Index: integer): UTF8String;
begin
  if (Index < 0) or (Index > High(fEntries)) then
  begin
    Result := '';
    Exit;
  end;
  Result := FilterCaption(fEntries[Index].Filter) + ': ' + fEntries[Index].Text;
end;

end.
