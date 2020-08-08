unit Horse.Core.RouterTree;
{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}
interface

uses
  {$IF DEFINED(FPC)}
  SysUtils, Generics.Collections, fpHTTP, Horse.MethodType, Horse.Proc,
  {$ELSE}
    System.SysUtils, Web.HTTPApp, System.Generics.Collections,
  {$ENDIF}
   Horse.HTTP;

type
  {$IF DEFINED(FPC)}
    THorseCallback = procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc);
  {$ELSE}
    THorseCallback = reference to procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc);
  {$ENDIF}

  THorseRouterTree = class
  strict private
    FPrefix: string;
    FIsInitialized: Boolean;
    function GetQueuePath(APath: string; AUsePrefix: Boolean = True):  TQueue<string>;
    function ForcePath(APath: string): THorseRouterTree;
  private
    FPart: string;
    FTag: string;
    FIsRegex: Boolean;
    FMiddleware:  TList<THorseCallback>;
    FRegexedKeys:  TList<string>;
    FCallBack: TObjectDictionary<TMethodType, TList<THorseCallback>>;
    FRoute: TObjectDictionary<string, THorseRouterTree>;
    procedure RegisterInternal(AHTTPType: TMethodType; var APath: TQueue<string>; ACallback: THorseCallback);
    procedure RegisterMiddlewareInternal(var APath: TQueue<string>; AMiddleware: THorseCallback);
    function ExecuteInternal(APath: TQueue<string>; AHTTPType: TMethodType; ARequest: THorseRequest; AResponse: THorseResponse; AIsGroup: Boolean = False): Boolean;
    function CallNextPath(var APath: TQueue<string>; AHTTPType: TMethodType; ARequest: THorseRequest; AResponse: THorseResponse): Boolean;
    function HasNext(AMethod: TMethodType; APaths: TArray<string>; AIndex: Integer = 0): Boolean;
  public
    function CreateRouter(APath: string): THorseRouterTree;
    function GetPrefix(): string;
    procedure Prefix(APrefix: string);
    procedure RegisterRoute(AHTTPType: TMethodType; APath: string; ACallback: THorseCallback);
    procedure RegisterMiddleware(APath: string; AMiddleware: THorseCallback); overload;
    procedure RegisterMiddleware(AMiddleware: THorseCallback); overload;
    function Execute(ARequest: THorseRequest; AResponse: THorseResponse): Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

implementation

{ THorseRouterTree }

uses Horse.Commons, Horse.Exception;

procedure THorseRouterTree.RegisterRoute(AHTTPType: TMethodType; APath: string; ACallback: THorseCallback);
var
  LPathChain: TQueue<string>;
begin
  LPathChain := GetQueuePath(APath);
  try
    RegisterInternal(AHTTPType, LPathChain, ACallback);
  finally
    LPathChain.Free;
  end;
end;

function THorseRouterTree.CallNextPath(var APath: TQueue<string>; AHTTPType: TMethodType; ARequest: THorseRequest;
  AResponse: THorseResponse): Boolean;
var
  LCurrent: string;
  LAcceptable: THorseRouterTree;
  LFound: Boolean;
  LKey: string;
  LPathOrigin: TQueue<string>;
  LIsGroup: Boolean;
begin

  LIsGroup := False;
  LPathOrigin := APath;
  LCurrent := APath.Peek;
  LFound := FRoute.TryGetValue(LCurrent, LAcceptable);
  if(not LFound)then
  begin
     LFound := FRoute.TryGetValue(EmptyStr, LAcceptable);
    if(LFound)then
      APath := LPathOrigin;
    LIsGroup := LFound;
  end;
  if (not LFound) and (FRegexedKeys.Count > 0) then
  begin
    for LKey in FRegexedKeys do
    begin
      FRoute.TryGetValue(LKey, LAcceptable);
      if LAcceptable.HasNext(AHTTPType, APath.ToArray) then
      begin
        LAcceptable.ExecuteInternal(APath, AHTTPType, ARequest, AResponse);
        Break;
      end;
    end;
  end
  else if LFound then
    LAcceptable.ExecuteInternal(APath, AHTTPType, ARequest, AResponse, LIsGroup);
  Result := LFound;
end;

constructor THorseRouterTree.Create;
begin
  FMiddleware :=  TList<THorseCallback>.Create;
  FRoute :=  TObjectDictionary<string, THorseRouterTree>.Create([doOwnsValues]);
  FRegexedKeys := TList<string>.Create;
  FCallBack := TObjectDictionary<TMethodType, TList<THorseCallback>>.Create;
  FPrefix := '';
end;

destructor THorseRouterTree.Destroy;
begin
  FMiddleware.Free;
  FreeAndNil(FRoute);
  FRegexedKeys.Clear;
  FRegexedKeys.Free;
  FCallBack.Free;
  inherited;
end;

function THorseRouterTree.Execute(ARequest: THorseRequest; AResponse: THorseResponse): Boolean;
var
  LQueue:  TQueue<string>;
begin
  LQueue := GetQueuePath(THorseHackRequest(ARequest).GetWebRequest.PathInfo, False);
  try
    Result := ExecuteInternal(LQueue, {$IF DEFINED(FPC)} StringCommandToMethodType( THorseHackRequest(ARequest).GetWebRequest.Method ) {$ELSE} THorseHackRequest(ARequest).GetWebRequest.MethodType{$ENDIF}, ARequest, AResponse);
  finally
    LQueue.Free;
  end;
end;

function THorseRouterTree.ExecuteInternal(APath:  TQueue<string>; AHTTPType: TMethodType; ARequest: THorseRequest;
  AResponse: THorseResponse; AIsGroup: Boolean = False): Boolean;
var
  LCurrent: string;
  LIndex, LIndexCallback: Integer;
  LCallback: TList<THorseCallback>;
  LFound: Boolean;
  {$IFNDEF FPC}
  LNext: TProc;
  {$ENDIF}

  {$IF DEFINED(FPC)}
  procedure InternalNext();
  begin
      inc(LIndex);
      if (FMiddleware.Count > LIndex) then
      begin
        LFound:= True;
        Self.FMiddleware.Items[LIndex](ARequest, AResponse, @InternalNext);
        if (FMiddleware.Count > LIndex) then
          InternalNext;
      end
      else if (APath.Count = 0) and assigned(FCallBack) then
      begin
        inc(LIndexCallback);
        if  FCallBack.TryGetValue(AHTTPType, LCallback) then
        begin
          if (LCallback.Count > LIndexCallback) then
          begin
            try
              LFound:= True;
              LCallback.Items[LIndexCallback](ARequest, AResponse, @InternalNext);
            except
              on E: Exception do
              begin
                if (not (E is EHorseCallbackInterrupted)) and (not (E is EHorseException)) then
                  AResponse.Send('Internal Application Error').Status(THTTPStatus.InternalServerError);
                raise;
              end;
            end;
            if (LCallback.Count > LIndexCallback) then
              InternalNext;
          end;
        end
        else
          AResponse.Send('Method Not Allowed').Status(THTTPStatus.MethodNotAllowed);
      end
      else
        LFound := CallNextPath(APath, AHTTPType, ARequest, AResponse);
  end;
  {$ENDIF}
begin

  if not AIsGroup then
    LCurrent := APath.Dequeue;

  LIndex := -1;
  LIndexCallback := -1;
  if Self.FIsRegex then
    ARequest.Params.Add(FTag, LCurrent);

  try
    {$IF DEFINED(FPC)}
    InternalNext;
    {$ELSE}
    LNext := procedure
      begin
        inc(LIndex);
        if (FMiddleware.Count > LIndex) then
        begin
          LFound := True;
          Self.FMiddleware.Items[LIndex](ARequest, AResponse, LNext);
          if (FMiddleware.Count > LIndex) then
            LNext;
        end
        else if (APath.Count = 0) and assigned(FCallBack) then
        begin
          inc(LIndexCallback);
          if FCallBack.TryGetValue(AHTTPType, LCallback) then
          begin
            if (LCallback.Count > LIndexCallback) then
            begin
              try
                LFound := True;
                LCallback.Items[LIndexCallback](ARequest, AResponse, LNext);
              except
                on E: Exception do
                begin
                  if (not(E is EHorseCallbackInterrupted)) and (not(E is EHorseException)) then
                    AResponse.Send('Internal Application Error').Status(THTTPStatus.InternalServerError);
                  raise;
                end;
              end;
              if (LCallback.Count > LIndexCallback) then
                LNext;
            end;
          end
          else
            AResponse.Send('Method Not Allowed').Status(THTTPStatus.MethodNotAllowed);
        end
        else
          LFound := CallNextPath(APath, AHTTPType, ARequest, AResponse);
      end;
    {$ENDIF}
  finally
  {$IFNDEF FPC}
    LNext:= nil;
  {$ENDIF}
    Result := LFound;
  end;
end;

function THorseRouterTree.ForcePath(APath: string): THorseRouterTree;
begin
  if not FRoute.TryGetValue(APath, Result)  then
  begin
    Result := THorseRouterTree.Create;
    FRoute.Add(APath, Result);
  end;
end;

function THorseRouterTree.CreateRouter(APath: string): THorseRouterTree;
begin
  Result := ForcePath(APath);
end;

procedure THorseRouterTree.Prefix(APrefix: string);
begin
  FPrefix := '/'+APrefix.Trim(['/']);
end;

function THorseRouterTree.GetPrefix(): string;
begin
  Result := FPrefix;
end;

function THorseRouterTree.GetQueuePath(APath: string; AUsePrefix: Boolean = True): TQueue<string>;
var
  LPart: string;
  LSplitedPath: TArray<string>;
begin
  Result := TQueue<string>.Create;
  if AUsePrefix then
    APath := FPrefix+APath;
  LSplitedPath := APath.Split(['/']);
  for LPart in LSplitedPath do
  begin
    if (Result.Count > 0) and LPart.IsEmpty then
      Continue;
    Result.Enqueue(LPart);
  end;
end;

function THorseRouterTree.HasNext(AMethod: TMethodType; APaths: TArray<string>; AIndex: Integer = 0): Boolean;
var
  LNext: string;
  LNextRoute: THorseRouterTree;
  LKey: string;
begin
  Result := False;
  if (Length(APaths) <= AIndex) then
    Exit(False);
  if (Length(APaths) - 1 = AIndex) and ((APaths[AIndex] = FPart) or (FIsRegex)) then
    Exit(FCallBack.ContainsKey(AMethod) or (Amethod = mtAny));

  LNext := APaths[AIndex + 1];
  inc(AIndex);
  if FRoute.TryGetValue(LNext, LNextRoute) then
  begin
    Result := LNextRoute.HasNext(AMethod, APaths, AIndex);
  end
  else
  begin
    for LKey in FRegexedKeys do
    begin
      if FRoute.Items[LKey].HasNext(AMethod, APaths, AIndex) then
        Exit(true);
    end;
  end;
end;

procedure THorseRouterTree.RegisterInternal(AHTTPType: TMethodType; var APath: TQueue<string>; ACallback: THorseCallback);
var
  LNextPart: string;
  LCallbacks: TList<THorseCallback>;
begin
  if not FIsInitialized then
  begin
    FPart := APath.Dequeue;
    FIsRegex := FPart.StartsWith(':');
    FTag := FPart.Substring(1, Length(FPart) - 1);
    FIsInitialized := true;
  end
  else
    APath.Dequeue;

  if APath.Count = 0 then
  begin
    if not FCallBack.TryGetValue(AHTTPType, LCallbacks) then
    begin
      LCallbacks := TList<THorseCallback>.Create;
      FCallBack.Add(AHTTPType, LCallbacks);
    end;
    LCallbacks.Add(ACallback)
  end;

  if APath.Count > 0 then
  begin
    LNextPart := APath.Peek;
    ForcePath(LNextPart).RegisterInternal(AHTTPType, APath, ACallback);
    if ForcePath(LNextPart).FIsRegex then
      FRegexedKeys.Add(LNextPart);
  end;
end;

procedure THorseRouterTree.RegisterMiddleware(AMiddleware: THorseCallback);
begin
  FMiddleware.Add(AMiddleware);
end;

procedure THorseRouterTree.RegisterMiddleware(APath: string; AMiddleware: THorseCallback);
var
  LPathChain: TQueue<string>;
begin
  LPathChain := GetQueuePath(APath);
  try
    RegisterMiddlewareInternal(LPathChain, AMiddleware);
  finally
    LPathChain.Free;
  end;
end;

procedure THorseRouterTree.RegisterMiddlewareInternal(var APath: TQueue<string>; AMiddleware: THorseCallback);
var
  FCurrent: string;
begin
  FCurrent := APath.Dequeue;
  if APath.Count = 0 then
    FMiddleware.Add(AMiddleware)
  else
    ForcePath(APath.Peek).RegisterMiddlewareInternal(APath, AMiddleware);
end;

end.