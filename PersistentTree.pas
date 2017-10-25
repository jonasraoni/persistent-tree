{*
 * Persistent Tree: Persistent tree structure written in Pascal that can handle binary data through reference-counted streams.
 * Jonas Raoni Soares da Silva <http://raoni.org>
 * https://github.com/jonasraoni/persistent-tree
 *}

unit PersistentTree;

interface

uses
  Windows, Classes, SysUtils, StreamAdapter;

type
  EPersistentTree = class( Exception );

  TPersistentTree = class;

  TPersistentTreeClass = class of TPersistentTree;

  TPersistentTree = class( TStream )
  private
    FStream: IStream;
    FList: TList;
    FBaseClass: TPersistentTreeClass;
    FOwner, FParent: TPersistentTree;
    FOwnStream: Boolean;
    FDataFilename, FFilename: string;
    FLastPosition, FDataBegin, FDataLength: Int64;

    function GetItem(const Index: Integer): TPersistentTree;
    function GetCount: Integer;
    function GetStream: TStream;
    function Import( Item: TPersistentTree ): Boolean;
    procedure ClearData;
    procedure RecreateStream( const Pos: Int64; const Deep: Boolean = False );
    procedure Synchronize;

  protected
    //override to provide writing/reading notifications
    procedure Loaded; virtual;
    procedure Saving; virtual;

    //derived from TStream
    function GetSize: Int64; override;
    procedure SetSize(NewSize: Longint); override;
    procedure SetSize(const NewSize: Int64); override;

  public
    constructor Create; virtual;
    destructor Destroy; override;

    //derived from TStream
    function Read( var Buffer; Count: Longint ): Longint; override;
    function Write( const Buffer; Count: Longint ): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;

    function Truncate: Int64;
    function ReadString: string;
    procedure WriteString( const Data: string );

    procedure Save( const AFilename: string ); overload;
    procedure Save( Stream: TStream ); overload;
    procedure Load( const AFilename: string ); overload;
    procedure Load( Stream: IStream ); overload;
    procedure Load( Stream: TStream ); overload;

    function Add: TPersistentTree; overload;
    function Add( Item: TPersistentTree ): Integer; overload;
    procedure Insert( const Index: Integer; Item: TPersistentTree);
    function IndexOf( Item: TPersistentTree ): Integer;
    function Remove( Item: TPersistentTree ): Integer;
    procedure Delete( const Index: Integer);
    function Extract( Item: TPersistentTree ): TPersistentTree;
    procedure Exchange( const IndexA, IndexB: Integer );
    procedure Move(const CurIndex, NewIndex: Integer);
    procedure Clear;

    property Items[ const Index: Integer ]: TPersistentTree read GetItem; default;
    property Count: Integer read GetCount;
    property Owner: TPersistentTree read FOwner;
    property Parent: TPersistentTree read FParent;
    property Filename: string read FFilename;
    property BaseClass: TPersistentTreeClass read FBaseClass write FBaseClass;
  end;

  TPersistentTreeHeader = packed record
    Sig: array[0..4] of Char;
    Ver: Word;
  end;

const
  PERSISTENT_TREE_HEADER: TPersistentTreeHeader = ( Sig: 'PTREE'; Ver: 1 );

function GetTempFile: string;


implementation

function GetTempFile: string;
var
  Path: array[0..MAX_PATH-1] of Char;
begin
  GetTempPath( MAX_PATH, Path );
  GetTempFileName( Path, 'BUF', 0, Path );
  Result := Path;
end;

{ TPersistentTree }

procedure TPersistentTree.Clear;
var
  I: Integer;
begin
  for I := FList.Count - 1 downto 0 do
  begin
    TPersistentTree( FList[I] ).Free;
    FList.Delete( I );
  end;
end;

constructor TPersistentTree.Create;
begin
  FBaseClass := TPersistentTreeClass( Self.ClassType );
  FList := TList.Create;
  FStream := TStreamAdapter.Create( GetStream );
  FOwnStream := True;
end;

destructor TPersistentTree.Destroy;
begin
  ClearData;
  FList.Free;
  inherited;
end;

procedure TPersistentTree.Exchange(const IndexA, IndexB: Integer);
begin
  FList.Exchange( IndexA, IndexB );
end;

function TPersistentTree.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TPersistentTree.GetItem(const Index: Integer): TPersistentTree;
begin
  Result := FList[ Index ];
end;

function TPersistentTree.IndexOf(
  Item: TPersistentTree): Integer;
begin
  Result := FList.IndexOf( Item );
end;

procedure TPersistentTree.Load(const AFilename: string);
var
  FS: TFileStream;
  //Header: TPersistentTreeHeader;
begin
  FS := TFileStream.Create( AFilename, fmOpenRead or fmShareDenyWrite );
  try
    //FS.Read( Header, SizeOf( TPersistentTreeHeader ) );
    //if not CompareMem( @Header, @PERSISTENT_TREE_HEADER, SizeOf( TPersistentTreeHeader ) ) then
    //  raise EPersistentTree.CreateFmt( '%s.LoadFromFile :: "%s" Not Recognized', [ClassName, AFilename] );
    Load( FS );
    FFilename := AFilename;
  except
    FS.Free;
    raise;
  end;
end;

procedure TPersistentTree.Load(Stream: TStream);
begin
  Load( TStreamAdapter.Create( Stream ) );
end;

function TPersistentTree.Remove(Item: TPersistentTree): Integer;
begin
  Result := FList.Remove( Item );
  if Result >= 0 then
    Item.Free;
end;

procedure TPersistentTree.Save( const AFilename: string );
var
  FS: TFileStream;
begin
  FS := TFileStream.Create( AFilename, fmCreate or fmShareDenyWrite );
  try
    //FS.Write( PERSISTENT_TREE_HEADER, SizeOf( TPersistentTreeHeader ) );
    Save( FS );
  finally
    FS.Free;
  end;
end;

procedure TPersistentTree.Save(Stream: TStream);
var
  I: LongInt;
begin
  Seek( 0, soBeginning );
  Saving;

  FDataLength := Size;
  Stream.Write( FDataLength, SizeOf( FDataLength ) );
  Stream.CopyFrom( Self, 0 );

  I := FList.Count;
  Stream.Write( I, SizeOf( I ) );
  for I := 0 to FList.Count-1 do
    Self[I].Save( Stream );
end;

function TPersistentTree.Write( const Buffer; Count: Longint ): Longint;
begin
  if FOwnStream then
    Result := FStream.Write( Buffer, Count )
  else
  begin
    Synchronize;
    if Position + Count > Size then
      RecreateStream( Position );
    Result := FStream.Write( Buffer, Count );
    FLastPosition := FStream.Position;          
  end;

end;

function TPersistentTree.Read( var Buffer; Count: Longint): Longint;
begin
  if FOwnStream then
    Result := FStream.Read( Buffer, Count )
  else
  begin
    Synchronize;
    if Count < 0 then
      Count := 0
    else if Count > Size - Position then
      Count := Size - Position;
    Result := FStream.Read( Buffer, Count );
    FLastPosition := FStream.Position;
  end
end;

function TPersistentTree.Seek(const Offset: Int64;
  Origin: TSeekOrigin): Int64;
begin
  if FOwnStream then
    Result := FStream.Seek( Offset, Origin )
  else
  begin
    Synchronize;
    case Origin of
      soBeginning: Result := FDataBegin + Offset;
      soCurrent: Result := FStream.Position + Offset;
      soEnd: Result := FDataBegin + Size - Offset;
    else
      Result := 0;
    end;
    if Result > -1 then
      if Result <= FDataBegin + Size then
        Result := FStream.Seek( Result, soBeginning ) - FDataBegin
      else
      begin
        RecreateStream( Size );
        Result := FStream.Seek( Result, soBeginning );
      end;
    FLastPosition := FStream.Position;
  end;
end;

procedure TPersistentTree.SetSize(const NewSize: Int64);
begin
  if FOwnStream then
    FStream.Size := NewSize
  else begin
    if NewSize <= 0 then
      RecreateStream( 0 )
    else if NewSize > Size then
      RecreateStream( Size )
    else
    begin
      FDataLength := NewSize;
      Seek( 0, soEnd );
    end;
    FLastPosition := FStream.Position;
  end;
end;

procedure TPersistentTree.Synchronize;
begin
  if not FOwnStream and ( ( FStream.Position < FDataBegin ) or ( FStream.Position - FDataBegin > FDataLength ) ) then
    FStream.Seek( FLastPosition, soBeginning );
end;

procedure TPersistentTree.Load( Stream: IStream);
var
  I: LongInt;
begin
  ClearData;

  FStream := Stream;
  FOwnStream := False;

  Stream.Read( FDataLength, SizeOf( FDataLength ) );
  FDataBegin := FStream.Position;
  FLastPosition := FDataBegin;

  Stream.Seek( FDataLength, soCurrent );

  Stream.Read( I, SizeOf( I ) );
  for I := I - 1 downto 0 do
    Add.Load( FStream );

  //Seek( 0, soBeginning ); it isnt needed since synchonize will do it anyway
  Loaded;
  FStream.Seek( FDataBegin + FDataLength + SizeOf( I ), soBeginning );
end;

function TPersistentTree.Extract( Item: TPersistentTree): TPersistentTree;
begin
  Result := FList.Extract( Item );
  if Assigned( Result ) then begin
    Result.FParent := nil;
    Result.FOwner := nil;
    Result.RecreateStream( Size, True );
  end;
end;


function TPersistentTree.GetSize: Int64;
begin
  if FOwnStream then
    Result := FStream.Size
  else
    Result := FDataLength;
end;

procedure TPersistentTree.WriteString(const Data: string);
var
  I: LongWord;
begin
  I := Length( Data );
  Write( I, SizeOf( I ) );
  Write( Pointer( Data )^, I );
end;

function TPersistentTree.ReadString: string;
var
  I: LongWord;
begin
  Read( I, SizeOf( I ) );
  SetLength( Result, I );
  Read( Pointer( Result )^, I );
end;

procedure TPersistentTree.SetSize(NewSize: Integer);
begin
  SetSize( Int64( NewSize ) );
end;

procedure TPersistentTree.RecreateStream( const Pos: Int64; const Deep: Boolean );
var
  FS: TStream;
  I: Integer;
begin
  if not FOwnStream then
  begin
    FS := GetStream;
    if Pos > 0 then
    begin
      Seek( 0, soBeginning );
      FS.CopyFrom( Self, Pos );
    end;
    FStream := TStreamAdapter.Create( FS );
    FOwnStream := True;
  end;
  if Deep then
    for I := 0 to FList.Count - 1 do
      Self[I].RecreateStream( Self[I].Size, True );
end;

procedure TPersistentTree.ClearData;
begin
  FStream := nil;
  if FOwnStream then
    DeleteFile( FDataFilename );
  Clear;
end;

function TPersistentTree.GetStream: TStream;
begin
  FDataFilename := GetTempFile;
  Result := TFileStream.Create( FDataFilename, fmCreate or fmShareDenyWrite );
end;

function TPersistentTree.Add: TPersistentTree;
begin
  Result := TPersistentTreeClass( FBaseClass ).Create;
  Add( Result );
end;

function TPersistentTree.Add( Item: TPersistentTree): Integer;
begin
  if Import( Item ) then
    Result := FList.Add( Item )
  else
    Result := FList.IndexOf( Item );
end;

procedure TPersistentTree.Delete(const Index: Integer);
begin
  TPersistentTree( FList[Index] ).Free;
  FList.Delete( Index );
end;

procedure TPersistentTree.Insert(const Index: Integer; Item: TPersistentTree);
begin
  if Import( Item ) then
    FList.Insert( Index, Item )
  else
    FList.Move( FList.IndexOf( Item ), Index );
end;

procedure TPersistentTree.Move(const CurIndex, NewIndex: Integer);
begin
  FList.Move( CurIndex, NewIndex );
end;

function TPersistentTree.Truncate: Int64;
begin
  Result := Position;
  Size := Result;
end;

function TPersistentTree.Import(Item: TPersistentTree): Boolean;
begin
  Result := not Assigned( Item.FParent ) or ( ( Item.FParent <> Self ) and Assigned( Item.FParent.Extract( Item ) ) );
  if Result then
  begin
    Item.FParent := Self;
    if FOwner <> nil then
      Item.FOwner := FOwner
    else
      Item.FOwner := Self;
  end;
end;

procedure TPersistentTree.Saving;
begin
//
end;

procedure TPersistentTree.Loaded;
begin
//
end;

end.
