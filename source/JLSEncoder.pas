{
   JPEG-LS Codec
   This code is based on http://www.stat.columbia.edu/~jakulin/jpeg-ls/mirror.htm
   Converted from C to Pascal. 2017

   https://github.com/zekiguven/delphi_jpeg_jls

   author : Zeki Guven
}
unit JLSEncoder;

interface
uses 
  JLSGlobal, Classes, JLSBitIO, StrUtils, SysUtils, JLSJpegmark,
  JLSMelcode, JLSLossless, JLSBasecodec, Graphics;

const
  LESS_CONTEXTS =1;

TYPE
  TJLSEncoder=class(TJLSBaseCodec)
  private
    FOwnStreams:Boolean;
    application_header:int; { application bytes written in the header }
    all_header : int;       { all bytes of the header, including application bytes and JPEG-LS bytes }
    shift:int;              { Shift value for sparse images }
    palete:int;             { for paletized images }
    { close the line buffers }
    function closebuffers: int;
    { Initialize the buffers for each line }
    procedure initbuffers(comp: int);
    { Initialization Function - Reads in parameters from image}
    procedure initialize;
    { Read one row of pixel values }
    procedure read_one_line(line: PPixel; cols: int; infile: TStream);
    { Swap the pointers to the current and previous scanlines }
    procedure swaplines;

    procedure Init;

  public
    constructor Create; override;
    destructor Destroy;override;
    function Execute: Boolean;override;
    procedure SaveToFile(AFileName:string);

  end;



implementation

procedure TJLSEncoder.read_one_line(line: PPixel; cols:int; infile: TStream);
var
  line8 : PByte;
  i:int;
begin
  if (FImageInfo.bpp16=FALSE) then
  begin
    line8 :=  PByte(safealloc(cols));

    if infile.Read(line8^,cols)<>cols then
      error('Input file is truncated');

    for i:=0 to pred(cols) do
    begin
      line^:=PByteArrayAccess(line8)^[i];
      Inc(line);
    end;
    FreeMem(line8);
  end
  else
  begin
    if infile.Read(line,cols*2)<>cols*2 then
      error('Input file is truncated');
  end;
end;

procedure TJLSEncoder.SaveToFile(AFileName: string);
var
  Stream: TStream;
begin
  Stream := TFileStream.Create(AFileName, fmCreate);
  try
    FOutputStream.Position:=0;
    Stream.CopyFrom(FOutputStream, FOutputStream.Size);
  finally
    Stream.Free;
  end;
end;


procedure TJLSEncoder.initbuffers( comp:int);
var
  Ptr:PPixel;
begin
  pscanl0 := safecalloc(comp * (Width+LEFTMARGIN+RIGHTMARGIN+NEGBUFFSIZE), SizeOf(Pixel) );
  cscanl0 := safecalloc(comp * (Width+LEFTMARGIN+RIGHTMARGIN+NEGBUFFSIZE), SizeOf(Pixel) );

  { Adjust scan line pointers taking into account the margins,
     and also the fact that indexing for scan lines starts from 1
   }
  Ptr:=pscanl0; Inc(Ptr, comp * (LEFTMARGIN-1));
  pscanline := Ptr;
  Ptr:=cscanl0; Inc(Ptr, comp * (LEFTMARGIN-1));
  cscanline := Ptr;

  FBitIO.bitoinit();
end;



procedure TJLSEncoder.swaplines;
var
  temp : PPixel;
begin
  temp := pscanline;
  pscanline := cscanline;
  cscanline := temp;
end;

constructor TJLSEncoder.Create;
begin
  FOwnStreams:=False;
  inherited Create;
  shift:=0;        { Shift value for sparse images }
  palete:=0;        { for paletized images }
  init;
end;

destructor TJLSEncoder.Destroy;
begin

  if FOwnStreams then
  begin
    FInputStream.Free;
    FOutputStream.Free;
  end;

  inherited;
end;


function TJLSEncoder.closebuffers: int;
var
  pos : int;
begin
  FBitIO.bitoflush();

  FBitIO.fclose(FInputStream);

  pos := FBitIO.ftell(FOutputStream);

  FBitIO.fclose(FOutputStream);

  FreeMem(pscanl0);
  FreeMem(cscanl0);

  result:=pos;
end;


procedure TJLSEncoder.initialize;
var
  color_mode_string: string;
  i:int;
begin
  { check that color mode is valid and pick color mode string }
  if ( FImageInfo.NEAR = 0 ) then
    lossy := FALSE
  else
    lossy := TRUE;

  case color_mode  of
      PLANE_INT:
        begin
          color_mode_string := plane_int_string;

        end;
      LINE_INT:
        begin
          color_mode_string := line_int_string;
        end;
      PIXEL_INT:
        begin
          color_mode_string := pixel_int_string;
          //if (components>1){
          //  fprintf(stderr,"ERROR: specified more than 1 input file in pixel interleaved mode\n");
          //  exit(10);
          //}
        end;
  else
      begin
      //fprintf(stderr,"ERROR: Invalid color mode %d\n",color_mode);
      //usage();
      //exit(10);
      end;
  end;


  //if ( verbose>1 ) then
  //    fprintf(msgfile,"Number of contexts (non-run): %d regular + %d EOR = %d\n",CONTEXTS-LESS_CONTEXTS,EOR_CONTEXTS,TOT_CONTEXTS-LESS_CONTEXTS);
  { Read image headers}

  //    if ( read_header_6(FInputStream, @FImageInfo.Width, @FImageInfo.Height, @alpha0, @(FImageInfo.components)) <> 0 ) then
  //      error('Could not read image header. Must be PPM or PGM file.');

  { Single component => PLANE_INT }
  if ( ((color_mode=LINE_INT) or (color_mode=PIXEL_INT)) and (FImageInfo.components=1)) then
  begin
    FLog.Append('Single component received: Color mode changed to PLANE INTERLEAVED');
    color_mode:=PLANE_INT;
    color_mode_string := plane_int_string;
  end;

  FImageInfo.alpha := alpha0+1;  { number read from file header is alpha-1 }
  FImageInfo.ceil_half_alpha := (FImageInfo.alpha+1) div 2;


  FImageInfo.highmask := FImageInfo.highmask -FImageInfo.alpha;
  { check that alpha is a power of 2 }
  alpha0:=FImageInfo.alpha;
  i:=-1;
  while IsTrue(alpha0) do
  begin
    alpha0:=shr_c(alpha0,1);
    inc(i)
  end;


  if ( FImageInfo.alpha <> (1 shl i) ) then
  begin
    FLog.Append(Format('Sorry, this version has been optimized for alphabet size = power of 2, got %d',[FImageInfo.alpha]));
    //Result:=False;
    //exit(10);
  end;


  { Check for 16 or 8 bit mode }
  if (FImageInfo.alpha <= MAXA16 ) and (FImageInfo.alpha > MAXA8) then
  begin
    FImageInfo.bpp16 := TRUE;
    lutmax := LUTMAX16;
  end
  else if (FImageInfo.alpha <= MAXA8) and (FImageInfo.alpha >= 1) then
  begin
    FImageInfo.bpp16 := FALSE;
    lutmax := LUTMAX8;
  end
  else begin
    //fprintf(stderr,"Got alpha = %d\n",alpha);
    //error("Bad value for alpha. Sorry...\n");
  end;

  { print out parameters }
  if (FEnableLog) then
  begin
    FLog.Append(Format('Image: cols=%d rows=%d alpha=%d comp=%d mode=%d (%s)',
       [width, height, alpha, components, color_mode, color_mode_string]));

  end;

  { compute auxiliary parameters for near-lossless (globals) }
  if (lossy=TRUE) then
  begin
    quant := 2*FImageInfo.NEAR+1;
    FImageInfo.qbeta := (FImageInfo.alpha + 2*FImageInfo.NEAR + quant-1 ) div quant;
    FImageInfo.beta := quant*FImageInfo.qbeta;
    ceil_half_qbeta := (FImageInfo.qbeta+1) div 2;
    FImageInfo.negNEAR := -FImageInfo.NEAR;
    if ( FEnableLog ) then
      FLog.Append(Format('Near-lossless mode: NEAR = %d  beta = %d  qbeta = %d',[FImageInfo.NEAR,FImageInfo.beta,FImageInfo.qbeta]));
  end;


  { compute bits per sample for input symbols }
  bpp:=1;
  while LongInt(1 shl bpp)< FImageInfo.alpha
    do  Inc(bpp);

  { check if alpha is a power of 2: }
  if ( FImageInfo.alpha <> (1 shl bpp) ) then
      need_lse := 1; { if not, MAXVAL will be non-default, and
             we'll need to specify it in an LSE marker }


  { compute bits per sample for unencoded prediction errors }
  FImageInfo.qbpp:=1;
  if (lossy=TRUE) then
    while LongInt(1 shl FImageInfo.qbpp)< FImageInfo.qbeta do  Inc(FImageInfo.qbpp)
  else
    FImageInfo.qbpp := bpp;


  if ( bpp < 2 ) then bpp := 2;

  { limit for unary part of Golomb code }
  if ( bpp < 8 ) then
      FImageInfo.limit := 2*(bpp + 8) - FImageInfo.qbpp -1
  else
      FImageInfo.limit := 4*bpp - FImageInfo.qbpp - 1;


  for i:=0 to pred(FImageInfo.components) do
  begin
    samplingx[i] := 1;
    samplingy[i] := 1;
  end;

  { Allocate memory pools. }
  initbuffers(FImageInfo.components);
end;


function TJLSEncoder.Execute : Boolean;
var
  n,n_c,n_r,my_i, n_s, i:int;
  tot_in, tot_out, pos0, pos1:long;
  temp_columns:int;
  MCUs_counted:int;
  local_scanl0, local_scanl1, local_pscanline, local_cscanline : PPixel;
  ptr:ppixel;
begin
  inherited Execute;
  tot_in := 0;
  tot_out := 0;

  application_header:=0;
  all_header := 0;
  local_scanl0:=NIL;
  local_scanl1:=NIL;
  { Parse the parameters, initialize }
  initialize;

  { Compute the number of scans }
  { Multiple scans only for PLANE_INT in this implementation }

  if (color_mode=PLANE_INT) then
    number_of_scans:=FImageInfo.components
  else
    number_of_scans := 1;


  { Write the frame header - allocate memory for jpegls header }
  head_frame := safecalloc(1,sizeof(tjpeg_ls_header));

  for n_s:=0 to pred(number_of_scans) do
    head_scan[n_s] := safecalloc(1,sizeof(tjpeg_ls_header));

  { Assigns columns/rows to head_frame }
  head_frame^.columns:=Width;
  head_frame^.rows:=Height;

  head_frame^.alp:=FImageInfo.alpha;
  head_frame^.comp:=FImageInfo.components;

  { Assign component id and samplingx/samplingy }
  for i:=0 to pred(FImageInfo.components) do
  begin
    head_frame^.comp_ids[i]:=i+1;
    head_frame^.samplingx[i]:=samplingx[i];
    head_frame^.samplingy[i]:=samplingy[i];
  end;

  head_frame^.NEAR:=FImageInfo.NEAR; { Not needed, scan information }
  head_frame^.need_lse:=need_lse; { Not needed, for commpletness  }
  head_frame^.color_mode:=color_mode; { Not needed, scan information }
  head_frame^.shift:=shift; { Not needed, scan information }

  for n_s:=0 to pred(number_of_scans) do
  begin
    head_scan[n_s]^.alp := FImageInfo.alpha;
    head_scan[n_s]^.NEAR:= FImageInfo.NEAR;
    head_scan[n_s]^.T1 := FT1;
    head_scan[n_s]^.T2 := FT2;
    head_scan[n_s]^.T3 := FT3;
    head_scan[n_s]^.RES := FImageInfo.RESET;
    head_scan[n_s]^.shift := shift;
    head_scan[n_s]^.color_mode := color_mode;
  end;

  if (color_mode=PLANE_INT) then { One plane per scan }
  begin
    for n_s:=0 to pred(number_of_scans) do
    begin
      head_scan[n_s]^.comp:=1;
      head_scan[n_s]^.comp_ids[0]:=n_s+1;
    end;
  end
  else begin
    for n_s:=0 to pred(number_of_scans) do
    begin
      head_scan[n_s]^.comp:=head_frame^.comp;
      for n_c:=0 to pred(head_frame^.comp) do
        head_scan[n_s]^.comp_ids[n_c]:=n_c+1;
    end;
  end;

  { Write SOI }
  all_header := FJpeg.write_marker(FOutputStream, JPEGLS_MARKER_SOI);

  { Write the frame }
  all_header :=all_header + FJpeg.write_jpegls_frame(FOutputStream, head_frame);

  { End of frame header writing }


  if ((FImageInfo.components>1)) then
  begin

    local_scanl0 := safecalloc(Width+LEFTMARGIN+RIGHTMARGIN+NEGBUFFSIZE,sizeof(pixel) );
    local_scanl1 := safecalloc(Width+LEFTMARGIN+RIGHTMARGIN+NEGBUFFSIZE,sizeof(pixel) );

    ptr:=local_scanl0;    inc(ptr, LEFTMARGIN-1);
    local_pscanline:= ptr;

    ptr:=local_scanl1;  inc(ptr, LEFTMARGIN-1);
    local_cscanline:= ptr;

  end;


  { Go through each scan and process line by line }
  for n_s:=0 to pred(number_of_scans) do
  begin

    { process scans one by one }

    if (n_s=0) then
    begin
      { The thresholds for the scan. Must re-do per scan is change. }
      set_thresholds(FImageInfo.alpha, FImageInfo.NEAR, @FT1, @FT2, @FT3);
      for i:=0 to pred(number_of_scans) do
      begin
        head_scan[n_s]^.T1:=FT1;
        head_scan[n_s]^.T2:=FT2;
        head_scan[n_s]^.T3:=FT3;
      end;
    end;

    { After the thresholds are set, write LSE marker if we have }
    { non-default parameters or if we need a mapping table }
    if ( need_lse <> 0 ) then
      all_header := all_header + FJpeg.write_jpegls_extmarker(FOutputStream, head_scan[n_s],LSE_PARAMS);

    { If using restart markers, write the DRI header }
    if ( need_restart <> 0 ) then
    begin
      head_scan[n_s]^.restart_interval := restart_interval;
      all_header := all_header + FJpeg.write_jpegls_restartmarker(FOutputStream, head_scan[n_s]);
    end;


    { Print out parameters }
    if FEnableLog then
      FLog.Append(Format('Parameters: T1=%d T2=%d T3=%d RESET=%d limit=%d',[T1, T2, T3,RESET,limit]));

    { Prepare LUTs for context quantization }
    { Must re-do when Thresholds change }
    prepareLUTs();

    if (lossy=TRUE) then  {  prepare div/mul tables for near-lossless quantization }
      prepare_qtables(FImageInfo.alpha, FImageInfo.NEAR);

    { Check for errors }
    check_compatibility(head_frame, head_scan[0],0,FLog);

    { Restart Marker is reset after every scan }
    MCUs_counted := 0;

    { Write the scan header }
    all_header := all_header + FJpeg.write_jpegls_scan(FOutputStream, head_scan[n_s]);
    pos0 := FBitIO.ftell(FOutputStream);  { position in output file, after header }

    { Initializations for each scan }
    { Start from 1st image row }
    n:=0;

    { initialize stats arrays }
    if (lossy=TRUE) then
      init_stats(FImageInfo.qbeta)
    else
      init_stats(FImageInfo.alpha);

    { initialize run processing }
    FMelcode.init_process_run;

    if (color_mode=LINE_INT) then    { line interleaved }
    begin

{***********************************************************************/
/*           Line interleaved mode with single file received           */
/***********************************************************************}

        if (lossy=FALSE) then
        begin
          Inc(n);
          { LOSSLESS mode }
          while (n <= Height) do
          begin

            ptr:=@(PWordArray(cscanline)^[FImageInfo.components+1]);
            read_one_line( ptr, FImageInfo.components*Width, FInputStream);
            tot_in :=tot_in + FImageInfo.components*Width;

            { 'extend' the edges }

            for n_c:=0 to pred(FImageInfo.components) do
            begin
              ppixelarray(cscanline)^[-FImageInfo.components+n_c] := ppixelarray(pscanline)^[FImageInfo.components+n_c];
              ppixelarray(cscanline)^[n_c]:= ppixelarray(pscanline)^[FImageInfo.components+n_c];
            end;

            for n_c:=0 to pred(FImageInfo.components) do
            begin

              if (FImageInfo.components > 1) then
              begin
                for my_i:=0 to pred(Width+LEFTMARGIN+RIGHTMARGIN) do
                begin
                  ppixelarray(local_cscanline)^[-1+my_i] := PPixelarray(cscanline)^[-FImageInfo.components+my_i*FImageInfo.components+n_c];
                  ppixelarray(local_pscanline)^[-1+my_i] := PPixelarray(pscanline)^[-FImageInfo.components+my_i*FImageInfo.components+n_c];
                end;
              end
              else begin
                local_cscanline:=cscanline;
                local_pscanline:=pscanline;
              end;

              { process the lines }
              FLossless.lossless_doscanline(PPixelArray(local_pscanline), PPixelArray(local_cscanline), Width, n_c);

            end;

             { 'extend' the edges }
            for n_c:=0 to pred(FImageInfo.components) do
              ppixelarray(cscanline)^[FImageInfo.components*(Width+1)+n_c]:= ppixelarray(cscanline)^[FImageInfo.components*Width+n_c];

            { make the current scanline the previous one }
            swaplines();

            { Insert restart markers if enabled }
            if IsTrue(need_restart) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              Inc(MCUs_counted);
            end;
            inc(n);
           end;

        end
        else
        begin
          Inc(n);
          { LOSSY mode }
          while (n <= Height) do
          begin
            ptr:=@(PWordArray(cscanline)^[FImageInfo.components+1]);

            read_one_line( ptr, FImageInfo.components*Width, FInputStream);

            tot_in :=tot_in + FImageInfo.components*Width;

            { 'extend' the edges }

            for n_c:=0 to pred(FImageInfo.components) do
            begin
              ppixelarray(cscanline)^[-FImageInfo.components+n_c] := ppixelarray(pscanline)^[FImageInfo.components+n_c];
              ppixelarray(cscanline)^[n_c]:= ppixelarray(pscanline)^[FImageInfo.components+n_c];
            end;

            for n_c:=0 to pred(FImageInfo.components) do
            begin

              if (FImageInfo.components > 1) then
              begin
                for my_i:=0 to pred(Width+LEFTMARGIN+RIGHTMARGIN) do
                begin
                  ppixelarray(local_cscanline)^[-1+my_i] := PPixelarray(cscanline)^[-FImageInfo.components+my_i*FImageInfo.components+n_c];
                  ppixelarray(local_pscanline)^[-1+my_i] := PPixelarray(pscanline)^[-FImageInfo.components+my_i*FImageInfo.components+n_c];
                end;
              end
              else begin
                local_cscanline:=cscanline;
                local_pscanline:=pscanline;
              end;

              { process the lines }
              FLossy.lossy_doscanline(PPixelArray(local_pscanline), PPixelArray(local_cscanline), Width, n_c);

              if (components>1) then
              begin
                for my_i:=0 to pred(Width+LEFTMARGIN+RIGHTMARGIN) do
                begin
                  ppixelarray(cscanline)^[-components+my_i*components+n_c] := PPixelarray(local_cscanline)^[-1+my_i];
                end;
              end;
            end;

             { 'extend' the edges }
            for n_c:=0 to pred(FImageInfo.components) do
              ppixelarray(cscanline)^[FImageInfo.components*(Width+1)+n_c]:= ppixelarray(cscanline)^[FImageInfo.components*Width+n_c];

            { make the current scanline the previous one }
            swaplines();

            { Insert restart markers if enabled }
            if IsTrue(need_restart) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              Inc(MCUs_counted);
            end;
            inc(n);
          end;

        end;
    end  { Closes part for color_mode=LINE_INT }
    else
    begin

      if (color_mode=PIXEL_INT) then
      begin
        {***********************************************************************
         *           Pixel interleaved mode with single file received          *
         ***********************************************************************}

        if (lossy=FALSE) then
        begin
          Inc(n);

          { LOSSLESS mode }
          while (n <= Height) do
          begin
            ptr:=@(PWordArray(cscanline)^[FImageInfo.components+1]);

            read_one_line( ptr, FImageInfo.components*Width, FInputStream);

            tot_in :=tot_in + FImageInfo.components*Width;

            { 'extend' the edges }

            for n_c:=0 to pred(FImageInfo.components) do
            begin
              ppixelarray(cscanline)^[-FImageInfo.components+n_c] := ppixelarray(pscanline)^[FImageInfo.components+n_c];
              ppixelarray(cscanline)^[n_c]:= ppixelarray(pscanline)^[FImageInfo.components+n_c];
            end;

            { process the lines }
            FLossless.lossless_doscanline_pixel(PPixelArray(pscanline), PPixelArray(cscanline), FImageInfo.components*Width);

            { 'extend' the edges }
            for n_c:=0 to pred(FImageInfo.components) do
              ppixelarray(cscanline)^[FImageInfo.components*(Width+1)+n_c]:= ppixelarray(cscanline)^[FImageInfo.components*Width+n_c];

            { make the current scanline the previous one }
            swaplines();

            { Insert restart markers if enabled }
            if IsTrue(need_restart) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              Inc(MCUs_counted);
            end;
            inc(n);
          end;
        end
        else
        begin
          Inc(n);

          { LOSSY mode }
          while (n <= Height) do
          begin
            ptr:=@(PWordArray(cscanline)^[FImageInfo.components+1]);

            read_one_line( ptr, FImageInfo.components*Width, FInputStream);

            tot_in :=tot_in + FImageInfo.components*Width;

            { 'extend' the edges }

            for n_c:=0 to pred(FImageInfo.components) do
            begin
              ppixelarray(cscanline)^[-FImageInfo.components+n_c] := ppixelarray(pscanline)^[FImageInfo.components+n_c];
              ppixelarray(cscanline)^[n_c]:= ppixelarray(pscanline)^[FImageInfo.components+n_c];
            end;

            { process the lines }
            FLossy.lossy_doscanline_pixel( PPixelArray(pscanline), PPixelArray(cscanline), FImageInfo.components*Width);

            { 'extend' the edges }
            for n_c:=0 to pred(FImageInfo.components) do
              ppixelarray(cscanline)^[FImageInfo.components*(Width+1)+n_c]:= ppixelarray(cscanline)^[FImageInfo.components*Width+n_c];

            { make the current scanline the previous one }
            swaplines();

            { Insert restart markers if enabled }
            if IsTrue(need_restart) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              Inc(MCUs_counted);
            end;
            inc(n);
          end;

        end;


      end  { Closes if PIXEL_INT }
      else
      begin { NON PIXEL_INT }

{***********************************************************************/
/*           Plane interleaved mode                    */
/***********************************************************************}

        if (lossy=FALSE) then
        begin
          { LOSSLESS mode }
          inc(n);

          while (n <= Height ) do
          begin

            temp_columns := Width;;

            ptr:=@(PWordArray(cscanline)^[1]);

            read_one_line(ptr, temp_columns, InputStream);

            tot_in :=tot_in + temp_columns;

            { 'extend' the edges }
            PPixelArray(cscanline)^[0]:= PPixelArray(pscanline)^[1];
            PPixelArray(cscanline)^[-1]:= PPixelArray(pscanline)^[1];

            { process the lines }
            FLossless.lossless_doscanline( PPixelArray(pscanline),
                                PPixelArray(cscanline),
                                temp_columns,
                                n_s);

            { 'extend' the edges }
            PPixelArray(cscanline)^[temp_columns+1] := PPixelArray(cscanline)^[temp_columns];

            { make the current scanline the previous one }
            swaplines; { c_swaplines(n_s)};

            { Insert restart markers if enabled }
            if (IsTrue(need_restart)) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              inc(MCUs_counted);
            end;
            inc(n);
          end; //while

        end // if
        else
        begin

          { LOSSY mode }
          Inc(n);
          while (n <= Height ) do
          begin

            temp_columns := Width;

            ptr:=@(PWordArray(cscanline)^[1]);

            read_one_line(ptr, temp_columns, InputStream);

            tot_in :=tot_in + temp_columns;

            { 'extend' the edges }
            PPixelArray(cscanline)^[0]:= PPixelArray(pscanline)^[1];
            PPixelArray(cscanline)^[-1]:= PPixelArray(pscanline)^[1];

            { process the lines }
            FLossy.lossy_doscanline( PPixelArray(pscanline),
                                PPixelArray(cscanline),
                                temp_columns,
                                n_s);

            { 'extend' the edges }
            PPixelArray(cscanline)^[temp_columns+1] := PPixelArray(cscanline)^[temp_columns];

            { make the current scanline the previous one }
            swaplines; { c_swaplines(n_s)};

            { Insert restart markers if enabled }
            if (IsTrue(need_restart)) then
            begin
              { Insert restart markers only after a restart interval }
              if ((MCUs_counted mod restart_interval) = 0) then
              begin
                FBitIO.bitoflush();
                FJpeg.write_marker(FOutputStream, (JPEGLS_MARKER_RSTm + ((MCUs_counted div restart_interval) mod 8)));
              end;
              inc(MCUs_counted);
            end;
            inc(n);
          end; //while

        end;  { End for each component in PLANE_INT }
      end;

    end;  { End for non LINE_INT}

    FBitIO.bitoflush();

  end;  { End of loop on scans }

  all_header := all_header + FJpeg.write_marker(FOutputStream, JPEGLS_MARKER_EOI);

  { Close down }
  FMelcode.close_process_run();
  pos1:= closebuffers;

  FreeMem(head_frame);
  for n_s:=0 to pred(number_of_scans) do
    FreeMem(head_scan[n_s]);

  if local_scanl0<>NIL then
   FreeMem(local_scanl0);
  if local_scanl1<>NIL then
   FreeMem(local_scanl1);

  { total bytes out, including JPEG-LS header, but not
     application-specific header bytes }

  tot_out := pos1*8;


  if IsTrue(need_restart) then
    FLog.Append(Format('Used restart markers with restart interval : %d',[restart_interval]));

  if FEnableLog then
    FLog.Append(Format('Marker segment bytes: %d',[all_header]));

  Result:=True;                                       { OK! }
end;


procedure TJLSEncoder.Init;
begin
  color_mode:=DEFAULT_COLOR_MODE;
  need_lse:=0;
  need_table:=0;
  need_restart:=0;
  restart_interval:=0;
  FImageInfo.components:=0;
  FT1:=0;
  FT2:=0;
  FT3:=0;

  FImageInfo.RESET:=DEFAULT_RESET;

  { Initialize NEAR to zero and loss-less mode }
  FImageInfo.NEAR := DEF_NEAR;
  lossy := FALSE;
  alpha0:=DEF_ALPHA;
end;

end.






