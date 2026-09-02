unit USongSearch;

(*
 * Suchausdruecke fuer die Liedersuche: AND, OR, Klammern und Jahresbereiche.
 *
 * Bewusst eine eigene Unit: Das Zerlegen und Auswerten eines Suchausdrucks
 * hat mit der Liederliste nichts zu tun, und nur so laesst es sich ohne
 * Fenster, Ton und geladene Lieder pruefen - das Spiel selbst startet auf
 * einem Server nicht.
 *)

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

interface

uses
  SysUtils,
  Classes,
  UUnicodeUtils;

type
  TSearchOp = (soTerm, soAnd, soOr, soNot);
  PSearchNode = ^TSearchNode;
  TSearchNode = record
    Op:        TSearchOp;
    Text:      UTF8String;  // bei soTerm: gesuchter Text, bereits normalisiert
    IsRange:   boolean;     // bei soTerm: Jahresbereich statt Textsuche
    RangeFrom: integer;
    RangeTo:   integer;
    Left:      PSearchNode;
    Right:     PSearchNode;
  end;

function BuildSearchTree(const Expr: UTF8String): PSearchNode;
procedure FreeSearchNode(Node: PSearchNode);
function EvalSearchNode(Node: PSearchNode; const Haystack: UTF8String;
                        Year: integer): boolean;
function ParseYearRange(const S: UTF8String; out FromYear, ToYear: integer): boolean;

// Sammelt die verschiedenen Werte mehrwertiger Felder (Sprache, Genre,
// Schlagworte) und legt sie alphabetisch in Dest ab.
procedure CollectDistinctValues(Source, Dest: TStrings);

implementation

procedure FreeSearchNode(Node: PSearchNode);
begin
  if (Node = nil) then
    Exit;
  FreeSearchNode(Node.Left);
  FreeSearchNode(Node.Right);
  Dispose(Node);
end;

// "1990-1999" -> 1990, 1999. Nur Ziffern auf beiden Seiten eines einzelnen
// Bindestrichs; alles andere ist ein gewoehnlicher Suchbegriff.
function ParseYearRange(const S: UTF8String; out FromYear, ToYear: integer): boolean;
var
  DashPos, I: integer;
  Left, Right: UTF8String;
begin
  Result := false;
  DashPos := Pos('-', S);
  if (DashPos < 2) or (DashPos = Length(S)) then
    Exit;
  Left  := Copy(S, 1, DashPos - 1);
  Right := Copy(S, DashPos + 1, Length(S) - DashPos);
  for I := 1 to Length(Left) do
    if not (Left[I] in ['0'..'9']) then Exit;
  for I := 1 to Length(Right) do
    if not (Right[I] in ['0'..'9']) then Exit;

  FromYear := StrToIntDef(Left, 0);
  ToYear   := StrToIntDef(Right, 0);
  // "1999-1990" ist offensichtlich derselbe Wunsch wie "1990-1999".
  if (FromYear > ToYear) then
  begin
    I := FromYear;
    FromYear := ToYear;
    ToYear := I;
  end;
  Result := true;
end;

function NewTermNode(const RawWord: UTF8String): PSearchNode;
begin
  New(Result);
  Result.Op := soTerm;
  Result.Left := nil;
  Result.Right := nil;
  Result.IsRange := ParseYearRange(RawWord, Result.RangeFrom, Result.RangeTo);
  Result.Text := LowerCase(TransliterateToASCII(RawWord));
end;

function NewOpNode(Op: TSearchOp; L, R: PSearchNode): PSearchNode;
begin
  // Faellt eine Seite weg (z.B. "abba AND" ohne zweiten Begriff), bleibt der
  // Ausdruck die andere Seite, statt zu einem Knoten mit Loch zu werden.
  if (L = nil) then
  begin
    Result := R;
    Exit;
  end;
  if (R = nil) then
  begin
    Result := L;
    Exit;
  end;
  New(Result);
  Result.Op := Op;
  Result.Text := '';
  Result.IsRange := false;
  Result.RangeFrom := 0;
  Result.RangeTo := 0;
  Result.Left := L;
  Result.Right := R;
end;

// Umschliesst einen Knoten mit einer Negation - oder gibt ihn unveraendert
// zurueck, wenn nicht negiert wird.
function NewNotNode(Node: PSearchNode; Negiert: boolean): PSearchNode;
begin
  if (not Negiert) or (Node = nil) then
  begin
    Result := Node;
    Exit;
  end;
  New(Result);
  Result.Op := soNot;
  Result.Text := '';
  Result.IsRange := false;
  Result.RangeFrom := 0;
  Result.RangeTo := 0;
  Result.Left := Node;
  Result.Right := nil;
end;

// Zerlegt in Woerter und Klammern. Klammern sind eigene Zeichen, damit
// "(abba" nicht als ein Wort durchgeht.
procedure TokenizeSearch(const Expr: UTF8String; Tokens: TStringList);
var
  I: integer;
  Current: UTF8String;

  procedure Flush;
  begin
    if (Current <> '') then
    begin
      Tokens.Add(Current);
      Current := '';
    end;
  end;

begin
  Current := '';
  for I := 1 to Length(Expr) do
  begin
    case Expr[I] of
      '(', ')':
        begin
          Flush;
          Tokens.Add(Expr[I]);
        end;
      '!':
        // Nur am Wortanfang ein Operator. Sonst waere nach einem Titel wie
        // "Hey!" oder "Wham!" nicht mehr zu suchen - dort steht das
        // Ausrufezeichen hinten und gehoert zum Wort.
        if (Current = '') then
          Tokens.Add('!')
        else
          Current := Current + Expr[I];
      ' ', #9:
        Flush;
      else
        Current := Current + Expr[I];
    end;
  end;
  Flush;
end;

(*
 * Rekursiver Abstieg ueber die Tokenliste.
 *
 *   Oder    := Und { 'OR' Und }
 *   Und     := Faktor { ['AND'] Faktor }
 *   Faktor  := '(' Oder ')' | Wort
 *
 * Dass in "Und" der Operator in eckigen Klammern steht, ist der Kern der
 * Rueckwaertsvertraeglichkeit: Zwei aufeinanderfolgende Woerter ohne
 * Operator werden weiterhin verundet.
 *)
function ParseOrExpr(Tokens: TStringList; var Index: integer): PSearchNode; forward;

function ParseFactor(Tokens: TStringList; var Index: integer): PSearchNode;
var
  Negiert: boolean;
  Inner: PSearchNode;
begin
  Result := nil;

  // Mehrere '!' heben sich gegenseitig auf, statt als Fehler zu gelten.
  Negiert := false;
  while (Index < Tokens.Count) and (Tokens[Index] = '!') do
  begin
    Negiert := not Negiert;
    Inc(Index);
  end;

  if (Index >= Tokens.Count) then
  begin
    // "!" ohne Begriff dahinter: nichts zu negieren, also nichts tun.
    Exit;
  end;

  if (Tokens[Index] = '(') then
  begin
    Inc(Index);
    Inner := ParseOrExpr(Tokens, Index);
    // Fehlende schliessende Klammer wird stillschweigend hingenommen: Wer
    // "(abba" tippt, sucht gerade noch weiter und soll nicht mit einer
    // Fehlermeldung unterbrochen werden.
    if (Index < Tokens.Count) and (Tokens[Index] = ')') then
      Inc(Index);
    Result := NewNotNode(Inner, Negiert);
    Exit;
  end;

  if (Tokens[Index] = ')') then
    Exit;

  // Ein Operator an dieser Stelle steht allein da - etwa "AND" ohne
  // Suchbegriff oder ein fuehrendes "OR". Er wird verworfen, statt zum
  // Suchwort zu werden: Grossgeschrieben ist AND/OR immer ein Operator,
  // sonst waere die Regel nicht mehr verlaesslich. Der Zeiger rueckt dabei
  // weiter, damit die aufrufende Schleife nicht stehen bleibt.
  if (Tokens[Index] = 'AND') or (Tokens[Index] = 'OR') then
  begin
    Inc(Index);
    Exit;
  end;

  Result := NewNotNode(NewTermNode(Tokens[Index]), Negiert);
  Inc(Index);
end;

function ParseAndExpr(Tokens: TStringList; var Index: integer): PSearchNode;
var
  Right: PSearchNode;
begin
  Result := ParseFactor(Tokens, Index);
  while (Index < Tokens.Count) do
  begin
    if (Tokens[Index] = 'OR') or (Tokens[Index] = ')') then
      Break;
    // Ausgeschriebenes AND ueberspringen; danach gilt dasselbe wie fuer zwei
    // benachbarte Woerter.
    if (Tokens[Index] = 'AND') then
    begin
      Inc(Index);
      if (Index >= Tokens.Count) then
        Break;
      if (Tokens[Index] = 'OR') or (Tokens[Index] = ')') then
        Break;
    end;
    Right := ParseFactor(Tokens, Index);
    if (Right = nil) then
      Break;
    Result := NewOpNode(soAnd, Result, Right);
  end;
end;

function ParseOrExpr(Tokens: TStringList; var Index: integer): PSearchNode;
var
  Right: PSearchNode;
begin
  Result := ParseAndExpr(Tokens, Index);
  while (Index < Tokens.Count) and (Tokens[Index] = 'OR') do
  begin
    Inc(Index);
    Right := ParseAndExpr(Tokens, Index);
    if (Right = nil) then
      Break;
    Result := NewOpNode(soOr, Result, Right);
  end;
end;

function BuildSearchTree(const Expr: UTF8String): PSearchNode;
var
  Tokens: TStringList;
  Index: integer;
begin
  Tokens := TStringList.Create;
  try
    TokenizeSearch(Expr, Tokens);
    Index := 0;
    Result := ParseOrExpr(Tokens, Index);
  finally
    Tokens.Free;
  end;
end;

(*
 * Wertet den Ausdruck gegen ein Lied aus.
 *
 * Ein Bereich wie "1990-1999" bezieht sich IMMER auf das Jahr, unabhaengig
 * davon, wonach gerade gesucht wird - ein anderes Zahlenfeld hat ein Lied
 * nicht. So laesst sich in der Titelsuche "dancing AND 1990-1999" schreiben,
 * also Titel und Jahrgang zugleich einschraenken. Der Preis: Ein Titel, der
 * woertlich "1990-1999" enthaelt, ist ueber diese Schreibweise nicht mehr zu
 * finden. Das ist der seltenere Fall.
 *)
(*
 * Die verschiedenen Werte eines mehrwertigen Feldes, alphabetisch.
 *
 * Sprache, Genre und Schlagworte stehen je Lied als eine Zeichenkette mit
 * Komma dazwischen ("Rock,Pop") - siehe ParseMultivaluedFilterHeaders in
 * USong. Ohne Zerlegen bekaeme man "Rock,Pop" als einen Wert und "Rock"
 * gar nicht.
 *
 * Doppelte werden ohne Ruecksicht auf Gross- und Kleinschreibung
 * zusammengefasst: "rock" und "Rock" sind fuer die Suche dasselbe, und zwei
 * fast gleiche Eintraege in der Liste waeren nur laestig. Welche
 * Schreibweise gewinnt, entscheidet die alphabetische Sortierung.
 *)
procedure CollectDistinctValues(Source, Dest: TStrings);
var
  I, J: integer;
  Teile: TStringList;
  Wert: UTF8String;
begin
  Dest.Clear;
  Teile := TStringList.Create;
  try
    // Sortiert und ohne Doppelte - das erledigt die Liste selbst.
    Teile.Sorted := true;
    Teile.CaseSensitive := false;
    Teile.Duplicates := dupIgnore;

    for I := 0 to Source.Count - 1 do
    begin
      Wert := Source[I];
      // Selbst zerlegen statt CommaText: Das wuerde Anfuehrungszeichen und
      // Leerzeichen nach eigenen Regeln deuten, und ein Genre wie
      // "Rock 'n' Roll" ginge dabei kaputt.
      J := Pos(',', Wert);
      while (J > 0) do
      begin
        if (Trim(Copy(Wert, 1, J - 1)) <> '') then
          Teile.Add(Trim(Copy(Wert, 1, J - 1)));
        Wert := Copy(Wert, J + 1, Length(Wert) - J);
        J := Pos(',', Wert);
      end;
      if (Trim(Wert) <> '') then
        Teile.Add(Trim(Wert));
    end;

    Dest.Assign(Teile);
  finally
    Teile.Free;
  end;
end;

function EvalSearchNode(Node: PSearchNode; const Haystack: UTF8String;
                        Year: integer): boolean;
begin
  if (Node = nil) then
  begin
    Result := true;
    Exit;
  end;

  case Node.Op of
    soAnd:
      Result := EvalSearchNode(Node.Left, Haystack, Year) and
                EvalSearchNode(Node.Right, Haystack, Year);
    soOr:
      Result := EvalSearchNode(Node.Left, Haystack, Year) or
                EvalSearchNode(Node.Right, Haystack, Year);
    soNot:
      Result := not EvalSearchNode(Node.Left, Haystack, Year);
    else
      begin
        if Node.IsRange then
          Result := (Year >= Node.RangeFrom) and (Year <= Node.RangeTo)
        else
          Result := UTF8ContainsStr(Haystack, Node.Text);
      end;
  end;
end;


end.
