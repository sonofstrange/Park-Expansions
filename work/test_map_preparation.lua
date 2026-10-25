local nativeLoadfile=loadfile
local function test(kind)
 local calls,yields=0,0
 api={save={GetSaveMetadata=function()return{tSave={sGameMode="sandbox",sGeome="taiga",parkExpansions=kind=="converted" and {} or nil}}end}}
 local R=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.research.lua'))()
 package.loadlib=function(path,symbol)
  assert(symbol=="Begin")
  return function(identifier,name,biome,nonce)
   calls=calls+1;assert(identifier=="__prepare_map__" and name=="" and biome=="taiga")
  end
 end
 loadfile=function(path,mode,env)
  assert(mode=="t" and type(env)=="table")
  if path:find("BridgeInfo",1,true)then return function()return{version=32,supported=true}end end
  if path:find("State-",1,true)then return function()return{status="working"}end end
  if path:find("Result-",1,true)then
   if yields==0 then return nil end
   return function()
    if kind=="failure"then return{status="error",message="Disk unavailable"}end
    return{status="map_ready",filename=kind=="invalid" and "../other.bin" or "TaigaSandbox.bin"}
   end
  end
  return nil
 end
 local world={parkLoadSaveManager={tLoadParkFromFileRequest={sFileName="/run/Parks/Sandbox/TaigaSandbox.bin"}}}
 if kind=="unsupported"then world.parkLoadSaveManager.tLoadParkFromFileRequest.sFileName="/run/Parks/Scenarios/TaigaSandbox.bin"end
 if kind=="old" or kind=="converted"then world.parkLoadSaveManager={tLoadParkFromSaveTokenRequest={cSaveToken={}}}end
 local result
 local co=coroutine.create(function()result=R.PrepareMap(world)end)
 for i=1,10 do
  local ok,err=coroutine.resume(co);assert(ok,err)
  if coroutine.status(co)=="dead"then break end
  yields=yields+1
 end
 assert(coroutine.status(co)=="dead")
 if kind=="old"or kind=="unsupported"then assert(calls==0 and result==true)
 elseif kind=="failure"or kind=="invalid"then assert(result==false and world.parkExpansionsMapFailed)
 else
  assert(calls==1 and yields==1 and result==true)
  assert(R.PrepareMap(world)==true and calls==1,"Session cache launched another worker")
 end
 loadfile=nativeLoadfile
 print("PASS map preparation "..kind)
end
for _,kind in ipairs({"fresh","converted","old","unsupported","failure","invalid"})do test(kind)end
