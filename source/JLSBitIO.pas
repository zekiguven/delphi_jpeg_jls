{
   JPEG-LS Codec
   This code is based on http://www.stat.columbia.edu/~jakulin/jpeg-ls/mirror.htm
   Converted from C to Pascal. 2017

   https://github.com/zekiguven/delphi_jpeg_jls

   author : Zeki Guven
}
unit JLSBitIO;

interface
uses
 Classes, SysUtils, JLSGlobal;

const
  BUFSIZE = ((16*1024)-NEGBUFFSIZE); { Size of input BYTE buffer }
  BITBUFSIZE=(8*SizeOf(LongWord));

type
  TJLSBitIO=class
    FInputStream:TStream;
    FOutputStream:TStream;
    zeroLUT : array [0..255] of int;      { table to find out number of leading zeros }
    { BIT I/O variables }
    reg : Longword;//ulong;     { BIT buffer for input/output }
    {
    'buff' is defined as 'rawbuff+4' in bitio.h, so that buff[-4]..buff[-1]
    are well defined. Those locations are used to "return" data to
    the byte buffer when flushing the input bit buffer .
    }

    fp:int;     { index into byte buffer }
    truebufsize:int;        { true size of byte buffer ( <= BUFSIZE) }
    foundeof:boolean;


    bits:int;  { number of bits free in bit buffer (on output) }
               { (number of bits free)-8 in bit buffer (on input)}

    negbuff : array [0..BUFSIZE+NEGBUFFSIZE-1] of Byte;    { byte I/O buffer, allowing for 4 "negative" locations  }
    constructor Create(AInputStream:TStream; AOutputStream:TStream);

    procedure bitoinit;
    procedure bufiinit;
    procedure bitoflush;
    procedure bitiflush;
    function buff : PByteArray;
    function fillinbuff(fil:TStream):Byte;
    procedure myputc(c:byte);
    procedure flushbuff;
    procedure fclose(fil:TStream);
    function ftell(fil:TStream):Int64;
    function mygetc:Int;
    procedure myungetc(x:Byte;fil:TStream);

    procedure createzeroLUT;
    procedure bitiinit;
    procedure fillbuffer(no:integer);
    procedure putbits(x:int; n:int);
    procedure put_ones(n:int);
    procedure put_zeros(n:int);
  end;

function myfeof(instrm:TStream):Boolean;

implementation

function myfeof(instrm:TStream):Boolean;
begin
  result:= instrm.Position=instrm.Size;
end;

procedure TJLSBitIO.fclose(fil:TStream);
begin

end;

function TJLSBitIO.ftell(fil:TStream):Int64;
begin
  Result:=fil.Position;
end;

{ creates the bit counting look-up table. }
procedure TJLSBitIO.createzeroLUT;
var
  i, j, k, l:int;
begin
  j := 1;
  k := 1;
  l := 8;
  for i := 0 to pred(256) do
  begin
    zeroLUT[i] := l;
    dec(k);
    if (k = 0) then
    begin
      k := j;
      dec(l);
      j := j * 2;
    end;
  end;
end;

{ loads more data in the input buffer (inline code )}
procedure  TJLSBitIO.fillbuffer(no:integer);
var
  x: byte;
begin
  assert(no+bits <= 24);
  reg := reg shl no;
  bits :=bits+ no;

  while (bits >= 0) do
  begin
    x := Byte(mygetc);
    if ( x = $ff ) then
    begin
      if ( bits < 8 ) then
      begin
        myungetc($ff, FInputStream);
        break;
      end
      else begin

        x := Byte(mygetc);

        if ( not IsTrue(x and  $80) ) then { non-marker: drop 0 }
        begin
          reg :=reg or ($ff shl bits) or ((x and $7f) shl (bits-7));
          bits :=bits - 15;
        end
        else begin
          { marker: hope we know what we're doing }
          { the "1" bit following ff is NOT dropped }
          reg :=reg or  ($ff shl bits) or (x shl (bits-8));
          bits :=bits - 16;
        end;

        continue;
      end;
    end;

    reg :=reg or ( x shl bits);
    bits :=bits- 8;
  end;
end;

{ Initializes the bit input routines }
procedure TJLSBitIO.bitiinit;
begin
  bits := 0;
  reg := 0;
  fillbuffer(24);
end;


function TJLSBitIO.buff : PByteArray;
begin
  Result:= @negbuff[NEGBUFFSIZE];
end;

function TJLSBitIO.fillinbuff(fil:TStream):Byte;
var
  i: int;
begin

  { remember 4 last bytes of current buffer (for "undo") }
  for i:=0 to pred(NEGBUFFSIZE) do
  begin
    negbuff[i] := negbuff[ Integer(fp+i) ];
  end;

  TrueBufSize := fil.Read(buff[0], BUFSIZE);

  if ( TrueBufSize < BUFSIZE ) then
  begin
      if ( TrueBufSize <= 0 ) then
      begin
        if (  foundeof ) then
        begin  { second attempt to read past EOF }
          //fprintf(stderr,"*** Premature EOF in compressed file\n");
          Result:=10;
          exit;
        end
        else
        begin
          { One attempt to read past EOF is OK  }
          foundeof := TRUE;
        end;
      end;
      { fill buffer with zeros }
      FillChar(buff^[TrueBufSize],BUFSIZE-TrueBufSize,0);
  end;

  fp := 1;
  result:=buff^[0];
end;

function TJLSBitIO.mygetc:Int;
begin
  result:= BUF_EOF;
  if (FInputStream.Size=FInputStream.Position) and (fp >= BUFSIZE) then Exit;

  if (fp >= BUFSIZE)
    then result:=FillInBuff(FInputStream)
    else
      begin
        result:=buff^[fp];
        inc(fp);
      end;
end;

procedure TJLSBitIO.myungetc(x:Byte;fil:TStream);
begin
  dec(fp);
  buff^[fp]:=x;
  //if  pByteArray(FDebugStream.Memory)[fp]<>buff^[fp]
  //  then raise Exception.Create('Error Message');
end;

{****************************************************************************
 *  OUTPUT ROUTINES
 ****************************************************************************}


procedure TJLSBitIO.flushbuff;
begin
  { fwrite must work correctly, even if fp is equal to 0 }
  FOutputStream.Write(buff[0],fp);
  fp := 0;
end;

procedure TJLSBitIO.myputc(c:byte);
begin
  if (fp >= BUFSIZE) then flushbuff;
  buff^[fp] := c;
  inc(fp);
end;

{
   Flush the input bit buffer TO A BYTE BOUNDARY. Return unused whole
   bytes to the byte buffer
 }
procedure TJLSBitIO.bitiflush;
var
  filled,discard,dbytes,i, k, treg:int;
  bp:PByte;
begin
  k:=0;
  treg:=0;
  filled := 24 - bits;    { how many bits at the MS part of reg
            have unused data. These correspond to
            at most filled+2 bits from the input
            stream, as at most 2 '0' bits might have
            been dropped by marker processing }

  dbytes := (filled+2) div 8;  { the coorrect number of bytes we need to
                                 "unget" is either dbytes or dbytes-1 }
     { this solution is more general than what is required here: it
       will work correctly even if the end of a scan is not followed
       by a marker, as will necessarily be the case with the standard JPEG
       format }

  while True do
  begin
    bp := @(buff^[0]);
    inc(bp, fp - dbytes);  { back-in the buffer }
    treg :=0;
    k := 0;
    for i:=0 to pred(dbytes) do
    begin
      if ( PByteArray(bp)^[Word(i-1)]=$FF) and ((PByteArray(bp)^[Word(i)] and $80)=0 ) then
      begin
        treg :=treg or PByteArray(bp)^[i] shl (BITBUFSIZE-7-k);
        k :=k+ 7;
      end
      else
      begin
        treg :=treg or (PByteArray(bp)^[i] shl (BITBUFSIZE-8-k));
        k :=k+ 8;
      end;
    end;

    if ( k <= filled ) then break;
    dec(dbytes);
  end;

  { check consistency }
  if ( filled-k > 7 ) then
  begin
    //fprintf(stderr,"bitiflush: inconsistent bits=%d filled=%d k=%d\n",bits,filled,k);
    //Result:=10
    exit;
  end;

  discard := filled-k;
  if ( treg <> int((reg shl discard)) ) then
  begin
    //fprintf(stderr,"bitiflush: inconsistent bits=%d discard=%d reg=%08x treg=%08x\n",bits, discard, reg, treg);
    exit;//(10);
  end;

  //if IsTrue( reg and (((1 shl discard)-1) shl (BITBUFSIZE-discard)) )
  //fprintf(stderr,"bitiflush: Warning: discarding nonzero bits; reg=%08x bits=%d discard=%d\n",reg,bits,discard);

  fp :=fp- dbytes;  { do the unget }
  if ( buff^[fp-1]=$ff) and (buff^[fp]=0 ) then inc(fp);

  bits := 0;
  reg := 0;
end;

{ Flushes the bit output buffer and the byte output buffer }
procedure TJLSBitIO.bitoflush;
var
  outbyte : uint;
begin
   while (bits < 32) do
   begin
    outbyte := shr_c(reg,24);
    myputc(outbyte);
    if ( outbyte = $ff ) then
    begin
      bits :=bits+ 7;
      reg :=reg shl 7;
      reg :=reg and ( not (1 shl (8*sizeof(reg)-1))); { stuff a 0 at MSB }
    end else begin
        bits :=bits+ 8;
        reg :=reg shl 8;
    end;
  end;
  flushbuff;
  bitoinit();
end;

{ Initializes the bit output routines }
procedure TJLSBitIO.bitoinit;
begin
  bits := 32;
  reg := 0;
  fp := 0;
end;

procedure TJLSBitIO.bufiinit;
begin
  { argument is ignored }
  fp := BUFSIZE;
  truebufsize := 0;
  foundeof := FALSE;
end;

constructor TJLSBitIO.Create(AInputStream, AOutputStream: TStream);
begin
  FInputStream:=AInputStream;
  FOutputStream:=AOutputStream;
end;

procedure TJLSBitIO.putbits(x:int; n:int);
var
  outbyte:uint;
begin
  assert((n <= 24) and (n >= 0) and ((1 shl n)>x));
  bits :=bits - n;
  reg := reg or Cardinal(x shl bits);
  while (bits <= 24) do
  begin
    if (fp >= BUFSIZE) then
    begin
      FOutputStream.Write(buff[0],fp);
      fp := 0;
    end;

    buff^[fp] := shr_c(reg,24);
    outbyte := buff^[fp];
    inc(fp);

    if ( outbyte = $ff )  then
    begin
      bits := bits + 7;
      reg := reg shl 7;
                                { stuff a 0 at MSB }
      reg := reg and (not (1 shl (8*sizeof(reg)-1)));
    end
    else
      begin
        bits :=bits + 8;
        reg :=reg shl 8;
      end;
  end;
end;


procedure TJLSBitIO.put_ones(n:int);
var
 nn:uint;
begin
  if ( n < 24 ) then
  begin
    putbits((1 shl n)-1,n);
  end
  else
  begin
    nn := n;

    while ( nn >= 24 ) do
    begin
      putbits((1 shl 24)-1, 24);
      nn :=nn - 24;
    end;

    if IsTrue( nn )
      then putbits((1 shl nn)-1, nn);
  end;
end;

procedure TJLSBitIO.put_zeros(n:int);
begin
  bits :=bits - n;
  while (bits <= 24) do
  begin
     if (fp >= BUFSIZE) then
     begin
       FOutputStream.Write(buff[0],fp);
       fp := 0;
     end;

     buff^[fp] := shr_c(reg, 24);
     inc(fp);
     reg :=reg shl 8;
     bits :=bits + 8;
  end;
end;

end.
