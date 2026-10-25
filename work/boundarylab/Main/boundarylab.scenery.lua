-- Convert the original backdrop placements into ordinary, saved scenery parts.
local g=_G
local api=g.api
local S={}
local clusters={
    {"NAT_Tree_Conifer_Larch_European_Cluster_01","NAT_Tree_Conifer_Larch_European_Large_01"},
    {"NAT_Tree_Conifer_Larch_European_Cluster_02","NAT_Tree_Conifer_Larch_European_Large_01"},
    {"NAT_Tree_Conifer_Pine_Aleppo_Cluster_01","NAT_Tree_Conifer_Pine_Aleppo_Large_01"},
    {"NAT_Tree_Conifer_Pine_Aleppo_Cluster_02","NAT_Tree_Conifer_Pine_Aleppo_Large_01"},
    {"NAT_Tree_Broadleaf_Olive_Cluster_01","NAT_Tree_Broadleaf_Olive_Large_01"},
    {"NAT_Tree_Broadleaf_Olive_Cluster_02","NAT_Tree_Broadleaf_Olive_Large_01"},
    {"NAT_Bush_Creosote_Flowerless_Cluster_01","NAT_Bush_Creosote_Flowerless_Large_01"},
}

function S.AddPrefabs(add)
    for _,entry in g.ipairs(clusters) do
        local source=g.require(entry[1].."_Skirt").GetRoot()
        local model=source.Properties.ModelName.Default
        -- Retain the cluster's actual mesh and asset package, with the ordinary
        -- game's interaction/render components so it can be selected and moved.
        local root={Prefab=entry[2].."_Game",Components={
            Model={ModelName=model},AssetPackageLoader=source.Components.AssetPackageLoader}}
        add("PE_"..entry[1],root)
        add("PE_"..entry[1].."_Game",{Prefab="PE_"..entry[1]})
    end
end

function S.Init()
    local Builder=g.require("forgeutils.builders.scenerypartbuilder")
    for _,entry in g.ipairs(clusters) do
        local part=Builder.new():asSimplePart():withID("PE_"..entry[1])
            :withVisualPrefab("PE_"..entry[1]):withScaleRange(0.2,5)
            :withNameFile("BuildingPartName_"..entry[2])
            :withDescriptionFile("BuildingPartName_"..entry[2])
        -- Existing clusters are restored, rather than added to the scenery browser.
        part:addToDB()
    end
end

function S.BeforeLoad(world)
    world.parkExpansionsScenery={complete=false,count=0}
    local serial=api.world.GetWorldAPIs().worldserialisation
    serial:RegisterWorldSerialisationClient("ParkExpansionsScenery",1,
        function(save)
            local state=world.parkExpansionsScenery
            save.complete=state.complete;save.count=state.count;save.source=state.source
        end,
        function(load)
            if load and load.complete==true then
                world.parkExpansionsScenery={complete=true,count=load.count or 0,source=load.source}
            end
            return true
        end,
        function(version) return version==0 or version==1 end)
end

local function wait(test,message)
    for frame=1,10800 do
        if test() then return end
        g.coroutine.yield()
    end
    g.error(message)
end

local function validate(data)
    g.assert(data and data.version==1,"Original scenery data is unavailable")
    g.assert(not data.error,data.error)
    g.assert(g.type(data.source)=="string" and #data.source==64,"Invalid scenery source hash")
    g.assert(g.type(data.groups)=="table" and #data.groups<=100,"Invalid scenery groups")
    local count=0
    for _,group in g.ipairs(data.groups) do
        g.assert(g.type(group.resource)=="string" and #group.resource<128 and
            (group.resource:match("^NAT_[%w_]+$") or group.resource:match("^PE_NAT_[%w_]+$")),"Invalid scenery resource")
        g.assert(g.type(group.instances)=="table","Invalid scenery placements")
        for _,row in g.ipairs(group.instances) do
            g.assert(#row==4,"Invalid scenery transform")
            for _,value in g.ipairs(row) do
                g.assert(g.type(value)=="number" and value==value and g.math.abs(value)<10000,"Invalid scenery coordinate")
            end
            local edge=g.math.max(g.math.abs(row[1]),g.math.abs(row[3]))
            g.assert(edge>=512 and edge<1020,"Scenery placement overlaps the original park or outer backdrop")
            count=count+1
            g.assert(count<=20000,"Too many scenery placements")
        end
    end
    return count
end

function S.AfterLoad(world,progress)
    local state=world.parkExpansionsScenery
    if not state or state.complete then return end
    local research=world.boundaryLabResearch or {}
    local converted=world.parkExpansionsConverted
    local filename=world.boundaryLabFilename or research.filename or (converted and converted.filename)
    if not (world.boundaryLabTerrainCreated or research.managed or converted) then return end
    if not filename or not filename:match("^%a+Sandbox%.bin$") then return end
    local w=api.world.GetWorldAPIs()
    local a,b=w.voxelterrain:GetWorldBounds(w.voxelterrain:GetPrimaryVoxelTerrainEntityID())
    if a:GetX()~=-1024 or a:GetZ()~=-1024 or b:GetX()~=1023 or b:GetZ()~=1023 then return end
    local preview,changedConstraints
    local ok,message=g.pcall(function()
        local chunk=g.assert(g.loadfile("Win64/ovldata/Mod_BoundaryLab/Maps/"..
            filename:gsub("%.bin$",".decor.lua"),"t",{}),"Original scenery cache is missing")
        local data=chunk()
        local count=validate(data)
        local Vector3=g.require("Vector3")
        local TransformQ=g.require("TransformQ")
        local Quaternion=g.require("Quaternion")
        progress(true,0,"Restoring original scenery…")
        g.coroutine.yield()
        -- The restored backdrop ring extends beyond the currently owned plots.
        -- This runs during loading, before research creates its height ceiling.
        w.park:DeactivateParkEditConstraints()
        changedConstraints=true
        local hierarchy=w.editors:CreateUndoOperationsHierarchy()
        hierarchy:SetCashAccumulate(false)
        local token=api.entity.CreateRequestCompletionToken()
        local created={}
        for _,group in g.ipairs(data.groups) do
            for _,row in g.ipairs(group.instances) do
                created[#created+1]={object=hierarchy:CreateNewPart(group.resource,token),row=row}
                if #created%100==0 then
                    progress(true,g.math.floor(#created*40/g.math.max(count,1)),"Restoring scenery: "..#created.."/"..count)
                    g.coroutine.yield()
                end
            end
        end
        wait(function() return api.entity.HaveRequestsCompleted(token) end,"Scenery assets did not finish loading")
        for index,entry in g.ipairs(created) do
            local row=entry.row
            local edit=hierarchy:StartEditingPart_Scenery(entry.object)
            edit:SetTransform(TransformQ.FromOrPos(Quaternion.FromYawPitchRoll(Vector3:new(row[4],0,0)),
                Vector3:new(row[1],row[2],row[3])))
            if index%100==0 then
                progress(true,40+g.math.floor(index*40/g.math.max(count,1)),"Positioning original scenery…")
                g.coroutine.yield()
            end
        end
        local busy
        busy,preview=api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())
        g.assert(preview,"Scenery preview was not created")
        wait(function() return api.undo.IsOperationComplete(busy) end,"Scenery preview timed out")
        wait(function() return api.undo.CanCommitPreview(preview)~=nil end,"Scenery validation timed out")
        g.assert(api.undo.CanCommitPreview(preview)==true,"Engine rejected original scenery restoration")
        progress(true,90,"Saving restored scenery…")
        local committed=api.undo.CommitPreview(preview)
        preview=nil
        -- The native placement clients now own the objects. This marker only
        -- prevents re-import: deletion, movement and saving remain normal game work.
        state.complete=true;state.count=count;state.source=data.source
        wait(function() return api.undo.IsOperationComplete(committed) end,"Scenery commit timed out")
        api.undo.Checkpoint({})
    end)
    if preview then
        local cancelled,cancelError=g.pcall(function()
            local token=api.undo.CancelPreview(preview)
            wait(function() return api.undo.IsOperationComplete(token) end,"Scenery cancellation timed out")
        end)
        if not cancelled then ok=false;message=g.tostring(message).."; "..g.tostring(cancelError) end
    end
    if changedConstraints then w.park:ActivateParkEditConstraints() end
    progress(false,100,"")
    if not ok then
        state.error=g.tostring(message)
        api.debug.Trace("Park Expansions scenery: "..state.error)
    end
end

return S
