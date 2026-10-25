-- Native placement is simulated here; real-game editing/save/reload is a user test.
local nativeLoadfile=loadfile
local nativeRequire=require
local V={}
function V:new(x,y,z) return {x=x,y=y,z=z,GetX=function(s)return s.x end,GetZ=function(s)return s.z end} end
local groups={{resource="NAT_Tree_Test",instances={{600,20,40,0.5},{-700,32,20,-1}}}}
local function run(kind)
    local created,placed,commits,cancels,activated,deactivated=0,{},0,0,0,0
    local saveFn,loadFn
    local suspended=0
    local expected=2
    if kind=="batches" or kind=="partial" then
        groups={{resource="NAT_Tree_Test",instances={}}}
        for i=1,260 do groups[1].instances[i]={600,20,40,0.5} end
        expected=260
    end
    local data={version=1,source=string.rep('a',64),groups=groups}
    if kind=='invalid' then data={version=1,source=string.rep('a',64),groups={{resource='NAT_Tree_Test',instances={{1,20,1,0}}}}} end
    local world={boundaryLabTerrainCreated=true,boundaryLabFilename='TaigaSandbox.bin'}
    local batchSize=0
    local previews=0
    local checks=0
    local hierarchy={SetCashAccumulate=function(_,value)assert(value==false)end,
        CreateNewPart=function(_,name)created=created+1;batchSize=batchSize+1;assert(batchSize<=128,"Unbounded native preview batch");assert(name=='NAT_Tree_Test');return created end,
        StartEditingPart_Scenery=function(_,id)return {SetTransform=function(_,value)placed[id]=value end}end,
        GetFullUndoChangeList=function()return 'scenery' end}
    local w={worldserialisation={RegisterWorldSerialisationClient=function(_,name,version,s,l)
        assert(name=='ParkExpansionsScenery' and version==1);saveFn=s;loadFn=l
    end},voxelterrain={GetPrimaryVoxelTerrainEntityID=function()return 1 end,
        GetWorldBounds=function()return V:new(-1024,0,-1024),V:new(1023,0,1023)end},
        editors={CreateUndoOperationsHierarchy=function()batchSize=0;return hierarchy end},
        park={DeactivateParkEditConstraints=function()deactivated=deactivated+1 end,
            ActivateParkEditConstraints=function()activated=activated+1 end}}
    api={save={CreateSaveSuspensionControl=function()return {SuspendSave=function()suspended=suspended+1 end,ResumeSave=function()suspended=suspended-1 end}end},
        player={GetGameOwner=function()return 1 end},world={GetWorldAPIs=function()return w end},debug={Trace=function()end},
        entity={FindPrefab=function(name)return kind~="missing" and name=="NAT_Tree_Test_Game" end,
            CompilePrefab=function()return nil end,CreateRequestCompletionToken=function()return 1 end,HaveRequestsCompleted=function()return true end},
        undo={IsBusy=function()return false end,PreviewChangeList=function()previews=previews+1;return 2,3 end,IsOperationComplete=function()return true end,
            CanCommitPreview=function()
                checks=checks+1
                return kind~='rejected' and not(kind=='partial' and previews==2) and
                    not(kind=='pending' and checks<12)
            end,
            GetCommitFailReasons=function()
                return {bUnknown=kind=='pending' and checks<12,bOutsidePark=kind=='rejected'}
            end,
            CommitPreview=function()commits=commits+1;return 4 end,
            CancelPreview=function()cancels=cancels+1;return 5 end,Checkpoint=function()end}}
    require=function(name)
        if name=='NAT_Tree_Test_Game' then return {GetRoot=function()return {}end}end
        if name=='Vector3' then return V end
        if name=='TransformQ' then return {FromOrPos=function(q,p)return {orientation=q,position=p}end}end
        if name=='Quaternion' then return {FromYawPitchRoll=function(v)return v end}end
        return nativeRequire(name)
    end
    loadfile=function(path,mode,environment)
        assert(path:match('TaigaSandbox%.decor%.lua$') and mode=='t' and type(environment)=='table')
        return function()return data end
    end
    local S=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.scenery.lua'))()
    S.BeforeLoad(world)
    local function restore()
        local co=coroutine.create(function()S.AfterLoad(world,function()end)end)
        for i=1,600 do
            local ok,message=coroutine.resume(co);assert(ok,message)
            if coroutine.status(co)=='dead' then return end
        end
        error('Scenery task did not finish')
    end
    if kind=='saved' then loadFn({complete=true,count=2,source=data.source}) end
    restore()
    if kind=='success' or kind=='batches' or kind=='pending' then
        assert(commits==math.ceil(expected/128) and created==expected and cancels==0)
        assert(placed[1].position.x==600 and placed[1].position.y==20 and placed[1].orientation.x==0.5)
        assert(world.parkExpansionsScenery.complete and world.parkExpansionsScenery.count==expected)
        local saved={};saveFn(saved)
        -- Simulate a player deleting or moving a native object: no re-import.
        placed[1]=nil
        S.BeforeLoad(world);loadFn(saved);restore()
        assert(created==expected and commits==math.ceil(expected/128) and placed[1]==nil,'Deleted scenery returned after reload')
    elseif kind=='partial' then
        assert(commits==1 and cancels==1 and not world.parkExpansionsScenery.complete)
        local saved={};saveFn(saved)
        assert(saved.nextIndex==129 and saved.count==128)
        S.BeforeLoad(world);loadFn(saved);restore()
        assert(commits==3 and created==388 and world.parkExpansionsScenery.complete)
        assert(world.parkExpansionsScenery.count==260,'Incomplete import did not resume at committed cursor')
    elseif kind=='saved' then assert(created==0 and commits==0)
    elseif kind=='invalid' or kind=='missing' then assert(created==0 and commits==0 and world.parkExpansionsScenery.error)
    else assert(commits==0 and cancels==1 and not world.parkExpansionsScenery.complete)
        assert(world.parkExpansionsScenery.error:find('bOutsidePark=true',1,true),'Native rejection reason missing')end
    assert(activated==deactivated,'Park edit constraints were not restored')
    assert(suspended==0,'Save suspension leaked')
    require=nativeRequire;loadfile=nativeLoadfile
    print('PASS scenery '..kind)
end
for _,kind in ipairs({'pending','success','saved','invalid','missing','rejected','partial','batches'})do run(kind)end

local definitions,parts={},{}
local builder={}
function builder:asSimplePart()self.simple=true;return self end
function builder:withID(value)self.id=value;return self end
function builder:withVisualPrefab(value)self.visual=value;return self end
function builder:withScaleRange(a,b)self.minimum=a;self.maximum=b;return self end
function builder:withNameFile(value)self.name=value;return self end
function builder:withDescriptionFile(value)self.description=value;return self end
function builder:addToDB()parts[#parts+1]=self end
require=function(name)
    if name=='forgeutils.builders.scenerypartbuilder' then return {new=function()return setmetatable({},{__index=builder})end}end
    assert(name:match('^NAT_.*_Skirt$'))
    return {GetRoot=function()return {Properties={ModelName={Default=name..'_mesh'}},
        Components={AssetPackageLoader={PackageNames={'OriginalNaturePackage'}}}}end}
end
local S=assert(nativeLoadfile('work/boundarylab/Main/boundarylab.scenery.lua'))()
S.AddPrefabs(function(name,root)assert(not definitions[name]);definitions[name]=root end)
S.Init()
assert(#parts==7)
for _,part in ipairs(parts)do
    assert(part.simple and part.visual==part.id and definitions[part.visual] and definitions[part.visual..'_Game'])
    local root=definitions[part.visual]
    assert(root.Prefab:match('_Game$') and root.Components.Model.ModelName:match('_mesh$'))
    assert(root.Components.AssetPackageLoader.PackageNames[1]=='OriginalNaturePackage')
    local game=definitions[part.visual..'_Game']
    assert(game.Prefab==root.Prefab and game.Components.Model.ModelName==root.Components.Model.ModelName,
        'Gameplay alias depends on another custom prefab instead of the stock gameplay parent')
    for _,name in ipairs({part.visual,part.visual..'_Game'}) do
        local module=package.loaded[name:lower()]
        assert(module and module.GetRoot()==definitions[name] and type(module.GetFlattenedRoot)=='function',
            'Native prefab module boilerplate missing')
        package.loaded[name:lower()]=nil
    end
end
require=nativeRequire
print('PASS backdrop-only clusters retain original meshes and packages with editable part definitions')
