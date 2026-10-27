local originalRequire=require
local hook
api={world={GetWorldAPIs=function()error('Grid setup must not resolve a pending native world')end}}
require=function(name)
    if name=='forgeutils.hookmanager' then return {AddHook=function(_,module,method,fn)
        assert(module=='CommonObjectCreator' and method=='CreateEnvironmentCaptureGrid');hook=fn
    end}end
    return originalRequire(name)
end
local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.InstallCaptureGridFix();require=originalRequire
R.LoadConfig=function()end;R.PrepareMap=function()return true end;R.AutoConvert=function()end
R.ReadConvertedSave=function()end
api.world.GetWorldAPIs=function()return{}end
local function vector(x,y)return{X=function()return x end,Y=function()return y end}end
-- Stock CommonObjectCreator uses floor(span/r) columns and sqrt(3/4)*r row
-- spacing, alternating full rows and one fewer column (verified bytecode).
local function count(width,depth,radius)
    local columns=math.max(2,math.floor(width/radius))
    local rows=math.max(2,math.floor(depth/(math.sqrt(3/4)*radius)))
    return rows*columns-math.ceil(rows/2)
end
assert(count(4095,4095,60)==5265,'Must reproduce oversized 0.50 capture grid')
local legacy=count(2047,2047,60)
assert(legacy==1306)
for _,size in ipairs({1024,2048,4096}) do
    local world={parkExpansionsTerrainSize=size};R.BeforeLoad(world)
    local minimum,maximum=vector(-size/2,-size/2),vector(size/2-1,size/2-1)
    local token,extra={},{}
    local result={}
    local co=coroutine.create(function()
        local received=hook(function(a,b,radius,height,completion,optional)
            assert(a==minimum and b==maximum and height==2.5 and completion==token and optional==extra)
            assert(radius==(size==4096 and 60*4095/2048 or 60))
            local points=count(size-1,size-1,radius)
            if size==4096 then assert(points<=legacy and points<3709) end
            for index=1,points+1 do result[index]=index end
            coroutine.yield('pending capture requests')
            return result
        end,minimum,maximum,60,2.5,token,extra)
        assert(received==result,'Original capture list must be retained for native cleanup')
    end)
    local ok,message=coroutine.resume(co);assert(ok,message)
    assert(message=='pending capture requests' and coroutine.status(co)=='suspended')
    assert(world.parkExpansionsCaptureCount==nil)
    ok,message=coroutine.resume(co);assert(ok,message)
    if size==4096 then
        assert(world.parkExpansionsCaptureCount==legacy and world.parkExpansionsCaptureSpan==4095)
    else assert(world.parkExpansionsCaptureRadius==nil) end
    print('PASS capture grid '..size..': full bounds, original token/list/yield; bounded 4K point count')
end
