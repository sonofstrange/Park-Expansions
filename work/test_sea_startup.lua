local originalLoadfile,originalLoadlib=loadfile,package.loadlib
for _,kind in ipairs({"ready","unsupported","old-dll","missing","invalid"}) do
    api={save={}}
    local R=assert(originalLoadfile('work/boundarylab/Main/boundarylab.research.lua'))()
    local calls=0
    package.loadlib=function(path,symbol)
        assert(symbol=="Begin")
        if kind=="missing" then return nil,"Missing DLL" end
        return function(identifier,name,size,nonce)
            assert(identifier=="__initialize_sea__" and size=="4096")
            assert(nonce:match("^%d+%-%d+$"))
            calls=calls+1
        end
    end
    loadfile=function(path,mode,env)
        assert(path:find("State-",1,true) and mode=="t" and type(env)=="table")
        if kind=="old-dll" then return nil end
        return function()
            if kind=="ready" then return {status="sea_ready",seaRaster=4096} end
            if kind=="invalid" then return {status="sea_ready",seaRaster=2048} end
            return {status="error",message="Sea code differs from the supported game build."}
        end
    end
    assert(R.InitializeNative()==(kind=="ready"))
    assert(R.NativeSeaReady()==(kind=="ready"))
    assert(R.InitializeNative()==(kind=="ready") and calls==(kind=="missing" and 0 or 1))
    if kind~="ready" then
        -- A broken startup must not fall through into 4K generation/native loading.
        package.loadlib=function()error("Must not launch a worker after failed native initialization")end
        R.LoadingProgress=function()end
        local world={parkLoadSaveManager={tLoadParkFromFileRequest={sFileName="/run/Parks/Sandbox/TaigaSandbox.bin"}},parkExpansionsConfig={Enable4KMap=true}}
        assert(R.PrepareMap(world)==false and world.parkExpansionsMapFailed)
        assert(type(world.parkExpansionsAutoError)=="string")
    end
    print('PASS startup Sea raster '..kind)
end
loadfile,package.loadlib=originalLoadfile,originalLoadlib

-- Exercise the actual CPTWorld wrapper: a saved 4K terrain must not enter the
-- unmodified native loader after a failed startup check.
local originalRequire,originalIO=require,io
local nativeCalls=0
local research={BeforeLoad=function(world)
    world.parkExpansionsTerrainSize=4096;world.parkExpansionsMapFailed=true
    world.parkExpansionsAutoError="Unsupported Sea code"
end,NativeSeaReady=function()return false end}
require=function(name)
    if name=="boundarylab.research" then return research end
    if name=="boundarylab.scenery" then return {} end
    return originalRequire(name)
end
io=nil
api={debug={Trace=function()end}}
local database=assert(originalLoadfile('work/boundarylab/Main/database.mod_boundarylabluadatabase.lua'))()
local worldClass={OnLoad=function()nativeCalls=nativeCalls+1 end}
database.AddLuaHooks(function(name,callback)assert(name=="Worlds.CPTWorld");callback(worldClass)end)
local world={parkLoadSaveManager={tLoadParkFromSaveTokenRequest={}}}
local ok,message=pcall(worldClass.OnLoad,world,{})
assert(not ok and message:find("4K park loading stopped",1,true) and nativeCalls==0)
require,io=originalRequire,originalIO
print('PASS unsupported saved 4K park stops before native loading')
