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
  TSearchOp = (soTerm, soAnd, soOr);
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
                        Year: integer; YearMode: boolean): boolean;
function ParseYearRange(const S: UTF8String; out FromYear, ToYear: integer): boolean;

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
begin
  Result := nil;
  if (Index >= Tokens.Count) then
    Exit;

  if (Tokens[Index] = '(') then
  begin
    Inc(Index);
    Result := ParseOrExpr(Tokens, Index);
    // Fehlende schliessende Klammer wird stillschweigend hingenommen: Wer
    // "(abba" tippt, sucht gerade noch weiter und soll nicht mit einer
    // Fehlermeldung unterbrochen werden.
    if (Index < Tokens.Count) and (Tokens[Index] = ')') then
      Inc(Index);
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

  Result := NewTermNode(Tokens[Index]);
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
 * ``YearMode`` schaltet die Bereichssuche frei. Sie gilt absichtlich nur bei
 * der Suche nach "Jahr": Im Gesamttext waere "1990-1999" ein gewoehnlicher
 * Suchbegriff, und dort steckt das Jahr nur als Zeichenkette zwischen
 * Kuenstler und Genre - eine Bereichsangabe koennte man dort nicht sinnvoll
 * von einem Titel wie "1990-1999 Greatest Hits" unterscheiden.
 *)
function EvalSearchNode(Node: PSearchNode; const Haystack: UTF8String;
                        Year: integer; YearMode: boolean): boolean;
begin
  if (Node = nil) then
  begin
    Result := true;
    Exit;
  end;

  case Node.Op of
    soAnd:
      Result := EvalSearchNode(Node.Left, Haystack, Year, YearMode) and
                EvalSearchNode(Node.Right, Haystack, Year, YearMode);
    soOr:
      Result := EvalSearchNode(Node.Left, Haystack, Year, YearMode) or
                EvalSearchNode(Node.Right, Haystack, Year, YearMode);
    else
      begin
        if (Node.IsRange and YearMode) then
          Result := (Year >= Node.RangeFrom) and (Year <= Node.RangeTo)
        else
          Result := UTF8ContainsStr(Haystack, Node.Text);
      end;
  end;
end;


end.
