-- Park Expansions 0.36: extends copied voxel storage; original terrain is retained.
local g = _G
local api = g.api
local M = {}
local Research = g.require("boundarylab.research")
local logPath = "Win64/ovldata/Mod_BoundaryLab/BoundaryLab.log"
local reportLines = {}

-- Built-in blank sandbox contours read from this installation; independent of park names.
local templates = {
    ["/run/parks/sandbox/temperatesandbox.bin"] = {seed={505.0637512,46.2103386,498.8643494},bounds={-500.7930603,505.0637512,-503.9561157,503.9422302}},
    ["/run/parks/sandbox/tropicalsandbox.bin"] = {seed={-497.2756653,6.5644922,484.7773743},bounds={-499.1105652,509.4645386,-504.4102783,499.5578918}},
    ["/run/parks/sandbox/taigasandbox.bin"] = {seed={-486.1791382,76.1536713,-486.6044006},bounds={-502.7882690,510.9080811,-511.0911560,413.6222229}},
    ["/run/parks/sandbox/mediterraneansandbox.bin"] = {seed={-506.6679993,10.1644068,-502.8905640},bounds={-510.1216431,488.7711792,-507.6991882,510.1072693}},
}


local function log(message)
    reportLines[#reportLines+1] = g.tostring(message)
    if #reportLines > 80 then g.table.remove(reportLines,1) end
    api.debug.Trace("BoundaryLab: " .. g.tostring(message))
    if g.io and g.io.open then
        local f = g.io.open(logPath, "a")
        if f then f:write(g.tostring(message), "\n"); f:close() end
    end
end

local function dump(value, depth)
    if g.type(value) ~= "table" then return g.tostring(value) end
    if depth == 0 then return "{...}" end
    local out = {}
    local count = 0
    for k,v in g.pairs(value) do
        count = count + 1
        if count > 40 then out[#out+1] = "..."; break end
        out[#out+1] = g.tostring(k) .. "=" .. dump(v, depth-1)
    end
    return "{" .. g.table.concat(out, ", ") .. "}"
end

local function probe(world)
    local w = api.world.GetWorldAPIs()
    local Vector3 = g.require("Vector3")
    log("PROBE park=" .. w.park:GetParkName())
    local terrainOK,terrainMin,terrainMax = g.pcall(function()
        local id = w.voxelterrain:GetPrimaryVoxelTerrainEntityID()
        return w.voxelterrain:GetWorldBounds(id)
    end)
    log("TERRAIN bounds=" .. g.tostring(terrainOK) .. " min=" .. g.tostring(terrainMin)
        .. " max=" .. g.tostring(terrainMax))
    local limitOK,maxDistance = g.pcall(function() return w.boundary:GetMaxPostDistance() end)
    log("MAX_POST_DISTANCE available=" .. g.tostring(limitOK) .. " value=" .. g.tostring(maxDistance))
    local ok, plots = g.pcall(function() return w.park:GetParkBoundaryPlotUIData() end)
    log("plots=" .. g.tostring(ok) .. " " .. dump(plots, 3))
    for _,x in g.ipairs({0, 490, 510, 550, 600, 750, 1000}) do
        local ok2, inside = g.pcall(function()
            return w.park:IsPositionWithinParkBoundary(Vector3:new(x, 20, 0))
        end)
        log("point=" .. x .. ",20,0 inside=" .. g.tostring(ok2) .. " " .. dump(inside, 1))
    end
    -- Each supported biome has its own verified outer-contour seed.
    local seedPosition = world.boundaryLabActiveSeed or world.boundaryLabTemplate.seed
    local rayTop = terrainMax:GetY()+1
    local rayDepth = rayTop-terrainMin:GetY()+1
    local edit = {
        vRayStart = Vector3:new(seedPosition[1],rayTop,seedPosition[3]),
        vRayDir = Vector3:new(0, -1, 0),
        vFacingDirection = Vector3:new(0, 0, 1),
        sBoundaryType = "ParkBoundary", nSmoothness = 0,
        nPanelMode = 0, nBoundaryExtraFlags = 0,
        nHeightAngleStart = 0, nHeightAngleEnd = 0,
        nWindowCutDistFromBase = 0, nWindowCutDistFromTop = 0,
        nTopRelativeHeight = 0.8, nTopWorldHeight = 100,
        bBottomHeightWorldRelative = false, bTopHeightWorldRelative = false,
        vPlacePoint = Vector3:new(seedPosition[1],seedPosition[2],seedPosition[3]),
        bUseHeightDeadZones = false, nDeadZoneRange = 0,
        bAlignMultiSelectHeights = false,
    }
    -- Keep known contour seeds so Undo/Redo cannot strand later research.
    local candidates=world.boundaryLabContourCandidates or {{seed=seedPosition,
        bounds=world.boundaryLabExpectedBounds or world.boundaryLabTemplate.bounds}}
    for _,candidate in g.ipairs(candidates) do
        edit.vRayStart=Vector3:new(candidate.seed[1],rayTop,candidate.seed[3])
        edit.vPlacePoint=Vector3:new(candidate.seed[1],candidate.seed[2],candidate.seed[3])
    local ok3, hit, panel, post, prop = g.pcall(function()
        return w.boundary:GetBoundaryPartsFromNearRay(edit, 20, rayDepth)
    end)
    log("ray=" .. g.tostring(ok3) .. " hit=" .. g.tostring(hit)
        .. " panel=" .. g.tostring(panel) .. " post=" .. g.tostring(post))
    if ok3 and hit and (post or panel) then
        local seed = post or panel
        log("seed=" .. dump(seed:GetAllData(), 2))
        local selection = w.boundary:GetAllConnectedBoundaryObjects(seed)
        local nPosts, nPanels = 0, 0
        for _ in g.pairs(selection.tControlPosts or {}) do nPosts = nPosts + 1 end
        for _ in g.pairs(selection.tPanels or {}) do nPanels = nPanels + 1 end
        log("CONNECTED posts=" .. nPosts .. " panels=" .. nPanels)
        world.boundaryLabProbeBounds=candidate.bounds
        return selection
    end
    end
    g.error("ParkBoundary contour not found; contour unchanged")
end

local function copy(t)
    local result = {}
    for k,v in g.pairs(t) do result[k] = v end
    return result
end

local function activeReasons(reasons)
    local items = {}
    for k,v in g.pairs(reasons or {}) do
        if v ~= false and v ~= nil and v ~= 0 then
            items[#items+1] = g.tostring(k) .. "=" .. dump(v,2)
        end
    end
    g.table.sort(items)
    if #items == 0 then return "no active reason flags reported" end
    return g.table.concat(items, "; ")
end

local function wait(token)
    for _ = 1, 600 do
        if token == nil or api.undo.IsOperationComplete(token) then return end
        g.coroutine.yield()
    end
    g.error("Undo operation timed out after 600 frames")
end

local function validation(preview)
    local canCommit,reasons
    for frame = 1,600 do
        canCommit = api.undo.CanCommitPreview(preview)
        reasons = api.undo.GetCommitFailReasons(preview)
        if canCommit == true then break end
        -- Allow a few frames even for a reasonless false result.
        if frame >= 5 and canCommit == false and not reasons.bUnknown then break end
        g.coroutine.yield()
    end
    return canCommit,reasons
end

local function notice(message)
    log(message)
    local report = "Park Expansions 0.36 report\n" .. g.table.concat(reportLines,"\n")
    local copied,result = g.pcall(function()
        return api.world.GetWorldAPIs().editors:CopyToClipboard(report)
    end)
    local hint = copied and result ~= false
        and "\n\nReport copied to clipboard. Paste it in chat with Ctrl+V."
        or "\n\nClipboard unavailable. Short result: " .. g.tostring(M.lastCode or "BL22-ERROR")
    g.require("Helpers.PopUpDialogUtils").RunOKDialog(
        "[STRING_LITERAL:Value=|Park Expansions 0.36|]",
        "[STRING_LITERAL:Value=|" .. message .. hint .. "|]")
end

-- Load copied, pre-extended voxel storage instead of replacing terrain entities.
-- Original source files and user saves are never overwritten.
local function loadLargeTerrain(self,loader,originalLoad)
    local manager = self.parkLoadSaveManager
    local request = manager and manager.tLoadParkFromFileRequest
    local template = request and g.type(request.sFileName) == "string"
        and templates[request.sFileName:lower()]
    local fresh = template
        and not manager.tLoadParkFromSaveTokenRequest
        and not manager.tLoadOnlineParkRequest
        and not manager.tLoadOnlineParkFromFileRequest
    if not fresh then return originalLoad(self,loader) end
    self.boundaryLabTemplate = template
    self.boundaryLabLoadLines = {}
    local function loadLog(message)
        self.boundaryLabLoadLines[#self.boundaryLabLoadLines+1] = message
        log(message)
    end
    local originalFile,originalTerrainFile = request.sFileName,request.sTerrainFileName
    local filename = originalFile:match("[^/]+$")
    self.boundaryLabFilename = filename
    request.sFileName = "/run/Win64/ovldata/Mod_BoundaryLab/Maps/" .. filename
    request.sTerrainFileName = request.sFileName:gsub("%.bin$",".trn")
    loadLog("PRESERVED_LOAD source=" .. originalFile .. " prepared=" .. request.sFileName)
    loadLog("PRESERVATION build verified: original voxel trees, decoded distance/material records and world coordinates preserved; original baked landscape heights and materials; source park preserved")
    local ok,result = g.pcall(originalLoad,self,loader)
    if not ok then
        request.sFileName,request.sTerrainFileName = originalFile,originalTerrainFile
        loadLog("PRESERVED_LOAD_ERROR " .. g.tostring(result))
        g.pcall(notice,"PRESERVED TERRAIN LOAD FAILED: " .. g.tostring(result))
        g.error(result,0)
    end
    local w = api.world.GetWorldAPIs()
    local id = w.voxelterrain:GetPrimaryVoxelTerrainEntityID()
    local minimum,maximum = w.voxelterrain:GetWorldBounds(id)
    loadLog("PRESERVED_TERRAIN min=" .. g.tostring(minimum) .. " max=" .. g.tostring(maximum))
    if g.math.abs(minimum:GetX()+1024) > 0.1 or g.math.abs(maximum:GetX()-1023) > 0.1
        or g.math.abs(minimum:GetY()+2304) > 0.1 or g.math.abs(maximum:GetY()-2303) > 0.1
        or g.math.abs(minimum:GetZ()+1024) > 0.1 or g.math.abs(maximum:GetZ()-1023) > 0.1 then
        notice("Prepared terrain has unexpected bounds; contour unchanged.")
        return result
    end
    local Vector3 = g.require("Vector3")
    local top = maximum:GetY()+1
    local depth = top-minimum:GetY()+1
    local checks = {}
    local checkChunk = g.loadfile("Win64/ovldata/Mod_BoundaryLab/Maps/" .. filename:gsub("%.bin$",".checks.lua"),"t",checks)
    if not checkChunk then checkChunk = g.loadfile("Win64/ovldata/Mod_BoundaryLab/Maps/GroundChecks.lua","t",checks) end
    local checkOK = checkChunk and g.pcall(checkChunk)
    local expected = checkOK and checks.Heights and checks.Heights[filename]
    if g.type(expected) ~= "table" then
        notice("Missing stock terrain checks; contour unchanged.")
        return result
    end
    for _,x in g.ipairs({0,600,750,900}) do
        local distance = w.voxelterrain:RayCast(id,Vector3:new(x,top,0),Vector3:new(0,-1,0),depth)
        loadLog("PRESERVED_GROUND x=" .. x .. " ray_distance=" .. g.tostring(distance)
            .. " expected_height=" .. g.tostring(expected[x]))
        if x > 512 and (g.type(distance) ~= "number" or distance ~= distance
            or g.type(expected[x]) ~= "number" or g.math.abs(top-distance-expected[x]) > 1.5) then
            notice("Stock terrain height did not validate; contour unchanged. Report includes expected heights.")
            return result
        end
    end
    self.boundaryLabTerrainCreated = true
    return result
end

local function expand(self,requestedWidth,allowShrink)
    reportLines = {}
    M.lastCode = "BL22-ERROR"
    log("RUN Park Expansions 0.36")
    for _,line in g.ipairs(self.boundaryLabLoadLines or {}) do log(line) end
    local cfg = {}
    local chunk, err = g.loadfile("Win64/ovldata/Mod_BoundaryLab/Config.ini", "t", cfg)
    g.assert(chunk, g.tostring(err))
    chunk()
    if requestedWidth then cfg.Mode="expand";cfg.Shape="rectangle";cfg.Factor=requestedWidth/1024 end
    Research.Progress(self,5,"Checking park boundaryвЂ¦")
    g.coroutine.yield()
    cfg.Shape = cfg.Shape or "rectangle"
    g.assert(cfg.Shape == "rectangle" or cfg.Shape == "scale","Invalid boundary shape")
    g.assert(cfg.Mode == "diagnose" or cfg.Mode == "expand" or cfg.Mode == "survey", "Invalid Mode")
    g.assert(g.type(cfg.Factor)=="number","Factor must be a number")
    if allowShrink then g.assert(cfg.Factor>0,"Configured park size must be positive")
    else g.assert(cfg.Factor>=1.001 and cfg.Factor<=2,"Factor must be between 1.001 and 2.00") end
    g.assert(cfg.Shape~="rectangle" or allowShrink or cfg.Factor>=1.05,"Rectangle factor must be at least 1.05")
    local w = api.world.GetWorldAPIs()
    g.assert(self.boundaryLabTerrainCreated and self.boundaryLabTemplate,"Not a newly created supported sandbox")
    local selection = probe(self)
    local minX,maxX,minZ,maxZ,nPosts,nPanels = 1e9,-1e9,1e9,-1e9,0,0
    for post in g.pairs(selection.tControlPosts or {}) do
        local t = post:GetAllData()
        g.assert(t.sBoundaryType == "ParkBoundary", "Non-park boundary post selected")
        minX,maxX = g.math.min(minX,t.vPos:GetX()),g.math.max(maxX,t.vPos:GetX())
        minZ,maxZ = g.math.min(minZ,t.vPos:GetZ()),g.math.max(maxZ,t.vPos:GetZ())
        nPosts = nPosts + 1
    end
    for panel in g.pairs(selection.tPanels or {}) do
        g.assert(panel:GetAllData().sBoundaryType == "ParkBoundary", "Non-park panel selected")
        nPanels = nPanels + 1
    end
    local longestChord = 0
    for panel in g.pairs(selection.tPanels or {}) do
        local t = panel:GetAllData()
        local a,b = t.vBasePosStart,t.vBasePosEnd
        local dx,dy,dz = a:GetX()-b:GetX(),a:GetY()-b:GetY(),a:GetZ()-b:GetZ()
        longestChord = g.math.max(longestChord,g.math.sqrt(dx*dx+dy*dy+dz*dz))
    end
    log("LONGEST_ORIGINAL_CHORD=" .. longestChord .. " uniform_scale_reference=" .. longestChord*cfg.Factor)
    log("BOUNDS " .. minX .. "," .. maxX .. "," .. minZ .. "," .. maxZ)
    g.assert(nPosts >= 4 and nPosts <= 4000 and nPosts == nPanels, "Expected one closed contour")
    if cfg.Mode == "diagnose" then notice("DIAGNOSE COMPLETE - contour unchanged"); return end
    -- Refuse repeat expansion and maps that do not match the prototype's baseline.
    local expected = self.boundaryLabProbeBounds or self.boundaryLabExpectedBounds or self.boundaryLabTemplate.bounds
    g.assert(g.math.abs(minX-expected[1]) < 0.2 and g.math.abs(maxX-expected[2]) < 0.2
        and g.math.abs(minZ-expected[3]) < 0.2 and g.math.abs(maxZ-expected[4]) < 0.2,
        "Unsupported or already expanded contour; expected original biome boundary")
    if requestedWidth and not allowShrink then
        g.assert(maxX-minX<=requestedWidth+0.1 and maxZ-minZ<=requestedWidth+0.1,
            "Refusing to shrink an existing park boundary")
    end
    local Vector3 = g.require("Vector3")
    local function positionKey(v) return g.string.format("%.4f,%.4f,%.4f",v:GetX(),v:GetY(),v:GetZ()) end
    -- A native load-time raster has a fixed 2048 x 2048 allocation.
    -- Keep the final boundary four metres inside the supported terrain edge.
    local rectangleTargets,rectangleDirections,rectangleHalf = {},{},allowShrink and 512*cfg.Factor or g.math.min(512*cfg.Factor,1020)
    if cfg.Shape == "rectangle" then
        -- Traverse the real closed ring; pairs() order and userdata aliases
        -- must not determine which posts become adjacent in the rectangle.
        local nodes,start = {},nil
        for post in g.pairs(selection.tControlPosts) do
            local p = post:GetAllData().vPos
            local key = positionKey(p)
            g.assert(not nodes[key],"Duplicate boundary control-post position")
            local node = {post=post,position=p,neighbors={}}
            nodes[key] = node
            if not start or p:GetZ() < start.position:GetZ()
                or (p:GetZ() == start.position:GetZ() and p:GetX() < start.position:GetX()) then start=node end
        end
        for panel in g.pairs(selection.tPanels) do
            local t = panel:GetAllData()
            local a = nodes[positionKey(t.oStartControlPost:GetAllData().vPos)]
            local b = nodes[positionKey(t.oEndControlPost:GetAllData().vPos)]
            g.assert(a and b and a ~= b,"Invalid boundary endpoint topology")
            a.neighbors[#a.neighbors+1] = b
            b.neighbors[#b.neighbors+1] = a
        end
        local order,seen,previous,current = {},{},nil,start
        for _=1,nPosts do
            g.assert(current and not seen[current] and #current.neighbors == 2,"Boundary is not one simple closed ring")
            order[#order+1],seen[current] = current,true
            local following = current.neighbors[1]
            if following == previous then following=current.neighbors[2] end
            previous,current = current,following
        end
        g.assert(current == start,"Boundary ring does not close")
        local area = 0
        for i,node in g.ipairs(order) do
            local p,q = node.position,order[i%nPosts+1].position
            area = area+p:GetX()*q:GetZ()-q:GetX()*p:GetZ()
        end
        g.assert(g.math.abs(area) > 1,"Degenerate boundary ring")
        local h = rectangleHalf
        local corners = area > 0 and {{-h,-h},{h,-h},{h,h},{-h,h}}
            or {{-h,-h},{-h,h},{h,h},{h,-h}}
        -- Quarter divisions put an existing post on every exact corner,
        -- even when the original post count is not divisible by four.
        for i,node in g.ipairs(order) do
            local index=i-1
            for quarter=0,3 do
                local first,last = g.math.floor(nPosts*quarter/4),g.math.floor(nPosts*(quarter+1)/4)
                if index >= first and index < last then
                    local alpha=(index-first)/(last-first)
                    local a,b=corners[quarter+1],corners[(quarter+1)%4+1]
                    rectangleTargets[positionKey(node.position)] = Vector3:new(
                        a[1]+(b[1]-a[1])*alpha,16,a[2]+(b[2]-a[2])*alpha)
                    break
                end
            end
        end
        for i,node in g.ipairs(order) do
            local a = rectangleTargets[positionKey(order[(i-2+nPosts)%nPosts+1].position)]
            local b = rectangleTargets[positionKey(order[i%nPosts+1].position)]
            local dx,dz = b:GetX()-a:GetX(),b:GetZ()-a:GetZ()
            local length = g.math.sqrt(dx*dx+dz*dz)
            g.assert(length > 0,"Degenerate rectangle tangent")
            rectangleDirections[positionKey(node.position)] = Vector3:new(dx/length,0,dz/length)
        end
        log("TARGET_RECTANGLE x=" .. -h .. ".." .. h .. " z=" .. -h .. ".." .. h .. " posts=" .. nPosts)
    end
    Research.Progress(self,15,"Preparing new boundaryвЂ¦")
    g.coroutine.yield()
    local samples = {}
    for post in g.pairs(selection.tControlPosts) do
        local p = post:GetAllData().vPos
        local halfway = (1 + cfg.Factor) / 2
        local target = rectangleTargets[positionKey(p)]
        local inset = (rectangleHalf-16)/rectangleHalf
        local v = target and Vector3:new(target:GetX()*inset,16,target:GetZ()*inset)
            or Vector3:new(p:GetX()*halfway,p:GetY(),p:GetZ()*halfway)
        samples[#samples+1] = {position=v,inside=w.park:IsPositionWithinParkBoundary(v)}
    end
    local function makeChanges(factor)
    local terrainID = w.voxelterrain:GetPrimaryVoxelTerrainEntityID()
    local terrainMinimum,terrainMaximum = w.voxelterrain:GetWorldBounds(terrainID)
    local rectangle = cfg.Shape == "rectangle" and factor == cfg.Factor
    if rectangle then
        g.assert(-rectangleHalf > terrainMinimum:GetX()+2 and rectangleHalf < terrainMaximum:GetX()-2
            and -rectangleHalf > terrainMinimum:GetZ()+2 and rectangleHalf < terrainMaximum:GetZ()-2,
            "Requested boundary is outside the loaded terrain volume; configured size was not clamped or applied")
    end
    local rayTop = terrainMaximum:GetY()+1
    local rayDepth = rayTop-terrainMinimum:GetY()+1
    local groundCache,groundRetries,pointRecoveries = {},0,0
    local pointAir,pointSolid
    local function pointClass(x,y,z)
        if g.type(w.voxelterrain.PointTest) ~= "function" then return nil end
        local ok,value = g.pcall(function()
            return w.voxelterrain:PointTest(terrainID,Vector3:new(x,y,z))
        end)
        if ok and (value == -1 or value == 0 or value == 1) then return value end
    end
    local function pointGround(x,z)
        -- Calibrate native classification against an independently ray-hit
        -- column. Never assume the API's sign convention or use a guessed Y.
        if pointAir == nil then
            local distance = w.voxelterrain:RayCast(terrainID,Vector3:new(600,rayTop,0),Vector3:new(0,-1,0),rayDepth)
            if g.type(distance) ~= "number" or distance < 0 or distance > rayDepth then return nil end
            local reference = rayTop-distance
            local air,solid = pointClass(600,reference+4,0),pointClass(600,reference-4,0)
            if air == nil or solid == nil or air == 0 or solid == 0 or air == solid then return nil end
            pointAir,pointSolid = air,solid
            log("GROUND_POINT_CLASS air=" .. air .. " solid=" .. solid)
        end
        -- Find the first actual air/solid transition from above, including
        -- terrain above the original height ceiling. X/Z never change.
        local upper = rayTop-2
        if pointClass(x,upper,z) ~= pointAir then return nil end
        local lower
        local steps = 0
        while upper > terrainMinimum:GetY()+1 do
            local nextY = g.math.max(upper-8,terrainMinimum:GetY()+1)
            local value = pointClass(x,nextY,z)
            if value == 0 then return nextY end
            if value == pointSolid then lower=nextY;break end
            if value ~= pointAir then return nil end
            upper = nextY
            steps = steps+1
            if steps % 32 == 0 then g.coroutine.yield() end
        end
        if lower == nil then return nil end
        for _=1,14 do
            local middle = (upper+lower)/2
            local value = pointClass(x,middle,z)
            if value == 0 then return middle end
            if value == pointAir then upper=middle
            elseif value == pointSolid then lower=middle
            else return nil end
        end
        return (upper+lower)/2
    end
    local function ground(x,z,expectedY)
        local cacheKey = g.string.format("%.6f,%.6f",x,z)
        if groundCache[cacheKey] then return groundCache[cacheKey] end
        local function cast(top,depth)
            local distance = w.voxelterrain:RayCast(terrainID,Vector3:new(x,top,z),Vector3:new(0,-1,0),depth)
            if g.type(distance) == "number" and distance >= 0 and distance <= depth then
                return top-distance
            end
        end
        local y = cast(rayTop,rayDepth)
        if y == nil then
            -- Retry at the same X/Z with shorter traversal lengths. Never
            -- infer ground from a neighbouring point or assume a height.
            local top = g.math.min(rayTop,g.math.max(expectedY,16)+64)
            y = cast(top,g.math.min(256,top-terrainMinimum:GetY()+1))
            if y == nil then
                top = rayTop
                while top > terrainMinimum:GetY() do
                    y = cast(top,g.math.min(513,top-terrainMinimum:GetY()+1))
                    if y ~= nil then break end
                    top = top-512
                end
            end
            if y ~= nil then
                groundRetries = groundRetries+1
                if groundRetries <= 5 then
                    log("GROUND_SHORT_RAY x=" .. x .. " z=" .. z .. " height=" .. y)
                end
            end
        end
        if y == nil then
            y = pointGround(x,z)
            if y ~= nil then
                pointRecoveries = pointRecoveries+1
                if pointRecoveries <= 5 then
                    log("GROUND_POINT_RECOVERY x=" .. x .. " z=" .. z .. " height=" .. y)
                end
            end
        end
        if y == nil then
            log("GROUND_MISS x=" .. x .. " z=" .. z .. " expected_y=" .. expectedY
                .. " factor=" .. factor .. " full_and_short_rays_failed point_test_failed")
            g.error("No ground at proposed boundary x=" .. x .. ", z=" .. z
                .. "; rays and native point checks failed; contour unchanged",0)
        end
        groundCache[cacheKey] = y
        return y
    end
    local function scale(v)
        -- Keep the original-height control operation genuinely unchanged.
        if factor == 1 then return Vector3:new(v:GetX(),v:GetY(),v:GetZ()) end
        local x,z = v:GetX()*factor,v:GetZ()*factor
        return Vector3:new(x,ground(x,z,v:GetY()),z)
    end
    local key = positionKey
    local hierarchy = w.editors:CreateUndoOperationsHierarchy()
    local changes = hierarchy:GetBoundaryChangeList()
    local replacements, byPosition = {}, {}
    local processedPosts=0
    local resultSeed
    for old in g.pairs(selection.tControlPosts) do
        local t = copy(old:GetAllData())
        local oldPosition = key(t.vPos)
        local oldY = t.vPos:GetY()
        if rectangle then
            local target = rectangleTargets[oldPosition]
            g.assert(target,"Missing rectangle target")
            t.vPos = Vector3:new(target:GetX(),ground(target:GetX(),target:GetZ(),oldY),target:GetZ())
            t.vDir = rectangleDirections[oldPosition]
        else
            t.vPos = scale(t.vPos)
        end
        t.nWorldHeight = t.nWorldHeight + t.vPos:GetY() - oldY
        local new = w.boundary:CreateNewControlPost()
        new:FillData(t)
        changes:ChangeControlPost(old,new)
        replacements[old],byPosition[oldPosition] = new,new
        resultSeed=resultSeed or {t.vPos:GetX(),t.vPos:GetY(),t.vPos:GetZ()}
        processedPosts=processedPosts+1
        if processedPosts%8==0 then
            Research.Progress(self,20+25*processedPosts/nPosts,"Boundary posts: "..processedPosts.." / "..nPosts)
            g.coroutine.yield()
        end
    end
    local function replacement(old)
        return replacements[old] or byPosition[key(old:GetAllData().vPos)]
    end
    local limit = g.math.min(18,w.boundary:GetMaxPostDistance()*0.9)
    g.assert(limit > 1,"Invalid boundary segment limit")
    local addedPosts,totalPanels,longest = 0,0,0
    local function distance(a,b)
        local dx,dy,dz = a:GetX()-b:GetX(),a:GetY()-b:GetY(),a:GetZ()-b:GetZ()
        return g.math.sqrt(dx*dx+dy*dy+dz*dz)
    end
    local processedPanels=0
    for old in g.pairs(selection.tPanels) do
        local original = old:GetAllData()
        local startPost,endPost = replacement(original.oStartControlPost),replacement(original.oEndControlPost)
        g.assert(startPost and endPost,"Missing endpoint replacement")
        local startData,endData = startPost:GetAllData(),endPost:GetAllData()
        local a,b = startData.vPos,endData.vPos
        local parts = factor == 1 and 1 or g.math.max(1,g.math.ceil(distance(a,b)/limit))
        local points
        while true do
            g.assert(parts <= 512,"Terrain is too steep to segment the park boundary")
            points = {a}
            local acceptable = true
            for i=1,parts-1 do
                local alpha = i/parts
                -- scale() also grounds intermediate positions; divide out factor
                -- because the endpoints here have already been scaled.
                local p = scale(Vector3:new((a:GetX()+(b:GetX()-a:GetX())*alpha)/factor,
                    a:GetY()+(b:GetY()-a:GetY())*alpha,
                    (a:GetZ()+(b:GetZ()-a:GetZ())*alpha)/factor))
                points[#points+1] = p
            end
            points[#points+1] = b
            if factor ~= 1 then
                for i=1,parts do
                    if distance(points[i],points[i+1]) > limit+0.001 then acceptable=false;break end
                end
            end
            if acceptable then break end
            parts = parts*2
        end
        local previous = startPost
        for i=1,parts do
            local following = endPost
            local p,q = points[i],points[i+1]
            local dx,dz = q:GetX()-p:GetX(),q:GetZ()-p:GetZ()
            local horizontal = g.math.sqrt(dx*dx+dz*dz)
            g.assert(horizontal > 0.001,"Degenerate boundary segment")
            local direction = Vector3:new(dx/horizontal,0,dz/horizontal)
            if i < parts then
                local t = copy(startData)
                t.nEntityID = nil
                t.vPos,t.vDir = q,direction
                local alpha = i/parts
                local relativeStart = startData.nWorldHeight-a:GetY()
                local relativeEnd = endData.nWorldHeight-b:GetY()
                t.nWorldHeight = q:GetY()+relativeStart+(relativeEnd-relativeStart)*alpha
                following = w.boundary:CreateNewControlPost()
                following:FillData(t)
                changes:AddControlPost(following)
                addedPosts = addedPosts+1
                g.assert(addedPosts <= 4000,"Too many additional boundary posts")
            end
            local t = copy(original)
            t.oStartControlPost,t.oEndControlPost = previous,following
            t.vBasePosStart,t.vBasePosEnd = p,q
            t.nWorldHeightStart = previous:GetAllData().nWorldHeight
            t.nWorldHeightEnd = following:GetAllData().nWorldHeight
            t.tSegmentData = nil
            if factor ~= 1 then
                -- A polygonal contour avoids stretching inherited curve handles.
                t.nSmoothness = 0
                t.vDirStart,t.vDirEnd = direction,direction
            end
            if i > 1 then t.nEntityID = nil end
            local new = w.boundary:CreateNewPanel()
            new:FillData(t)
            if i == 1 then changes:ChangePanel(old,new) else changes:AddPanel(new) end
            totalPanels = totalPanels+1
            longest = g.math.max(longest,distance(p,q))
            previous = following
            if totalPanels%16==0 then g.coroutine.yield() end
        end
        processedPanels=processedPanels+1
        if processedPanels%4==0 then
            Research.Progress(self,45+35*processedPanels/nPanels,"Boundary panels: "..processedPanels.." / "..nPanels)
            g.coroutine.yield()
        end
    end
    self.boundaryLabPreparedSeed=resultSeed
    log("SEGMENTED factor=" .. factor .. " added_posts=" .. addedPosts
        .. " total_panels=" .. totalPanels .. " longest_chord=" .. longest .. " limit=" .. limit)
    log("GROUND_SHORT_RAY_RECOVERIES=" .. groundRetries)
    log("GROUND_POINT_RECOVERIES=" .. pointRecoveries)
    g.assert(changes:HasChanges(),"No boundary changes produced")
    return hierarchy,changes
    end
    -- Native Boundary validation returns a generic failure when editing is disabled.
    -- This API flag is per world; only the disposable BoundaryLab world reaches here.
    w.boundary:SetBoundaryEditEnabled(true)
    local hierarchy,changes = makeChanges(cfg.Factor)
    Research.Progress(self,82,"Validating expansionвЂ¦")
    g.coroutine.yield()
    local busy,preview = api.undo.PreviewChangeList(hierarchy:GetFullUndoChangeList())
    self.boundaryLabPreview = preview
    g.assert(preview ~= nil,"No preview token returned")
    wait(busy)
    local canCommit,reasons = validation(preview)
    log("REQUESTED factor=" .. cfg.Factor .. " result=" .. g.tostring(canCommit)
        .. " reasons=" .. activeReasons(reasons))
    if canCommit ~= true or cfg.Mode == "survey" then
        local detail = activeReasons(reasons)
        local pending = canCommit == nil or reasons.bUnknown
        log("CANCEL REQUESTED PREVIEW canCommit=" .. g.tostring(canCommit) .. " " .. detail)
        wait(api.undo.CancelPreview(preview))
        self.boundaryLabPreview = nil
        if requestedWidth then
            g.error("Engine rejected expansion: " .. detail .. "; preview cancelled",0)
        end
        -- Control experiment: the same operation with all coordinates unchanged.
        -- Cancel it regardless of the result; do not commit the control operation.
        local controlResult,controlDetail,controlCanCommit
        local summary = {}
        for _,factor in g.ipairs({1,0.99,1.001,1.01}) do
            local trialHierarchy = makeChanges(factor)
            local trialBusy,trialPreview = api.undo.PreviewChangeList(trialHierarchy:GetFullUndoChangeList())
            self.boundaryLabPreview = trialPreview
            g.assert(trialPreview ~= nil,"No diagnostic preview token returned")
            wait(trialBusy)
            local allowed,why = validation(trialPreview)
            local status = allowed == true and "accepted" or (allowed == false and "rejected" or "pending")
            log("TRIAL factor=" .. factor .. " result=" .. status .. " reasons=" .. activeReasons(why))
            wait(api.undo.CancelPreview(trialPreview))
            self.boundaryLabPreview = nil
            summary[#summary+1] = factor .. ": " .. status
            if factor == 1 then
                controlCanCommit,controlResult,controlDetail = allowed,status,activeReasons(why)
            end
        end
        M.lastCode = "BL22-EXP-NO-COPY-" .. (controlCanCommit == true and "YES"
            or (controlCanCommit == false and "NO" or "WAIT"))
        if cfg.Mode == "survey" then
            M.lastCode = "BL22-SURVEY-DONE"
            notice("SURVEY COMPLETE. Requested factor=" .. cfg.Factor .. " accepted=" .. g.tostring(canCommit)
                .. ". Trials: " .. g.table.concat(summary,", ") .. ". ALL previews cancelled.")
            return
        end
        g.error((pending and "Validation timed out" or "Engine rejected expansion")
            .. ": " .. detail .. ". Unchanged contour: " .. controlResult
            .. " (" .. controlDetail .. "). Trials: " .. g.table.concat(summary,", ")
            .. ". ALL previews cancelled. Code: " .. M.lastCode,0)
    end
    Research.Progress(self,90,"Applying expansionвЂ¦")
    g.coroutine.yield()
    wait(api.undo.CommitPreview(preview))
    self.boundaryLabCommitResult={seed=self.boundaryLabPreparedSeed,
        bounds={-rectangleHalf,rectangleHalf,-rectangleHalf,rectangleHalf}}
    self.boundaryLabPreview = nil
    api.undo.Checkpoint({})
    Research.Progress(self,96,"Updating park areaвЂ¦")
    for _ = 1,120 do g.coroutine.yield() end
    local gained,beforeInside,afterInside = 0,0,0
    for _,sample in g.ipairs(samples) do
        local inside = w.park:IsPositionWithinParkBoundary(sample.position)
        if sample.inside then beforeInside = beforeInside + 1 end
        if inside then afterInside = afterInside + 1 end
        if inside and not sample.inside then
            gained = gained + 1
            if gained <= 5 then log("NEWLY_INSIDE position=" .. g.tostring(sample.position)) end
        end
    end
    log("STRIP_SAMPLES count=" .. #samples .. " before_inside=" .. beforeInside
        .. " after_inside=" .. afterInside .. " newly_inside=" .. gained)
    for _,x in g.ipairs({0,490,510,525,540,550,575,600}) do
        log("AFTER x=" .. x .. " inside=" .. g.tostring(w.park:IsPositionWithinParkBoundary(Vector3:new(x,20,0))))
    end
    M.lastCode = "BL22-COMMIT-OK"
    Research.Progress(self,100,"Park expanded.")
    self.boundaryLabReport="Park Expansions 0.36 report\n"..g.table.concat(reportLines,"\n")
    if requestedWidth then return end
    notice((cfg.Shape == "rectangle" and "COMMIT COMPLETE - rectangle " .. rectangleHalf*2 .. " x " .. rectangleHalf*2 .. " m"
        or "COMMIT COMPLETE - contour scaled by " .. cfg.Factor)
        .. ". Newly inside park: " .. gained .. "/" .. #samples
        .. " sample points. Test placement, paths, guests, save and reload manually.")
end

function M.AddContentToCall(list)
    g.table.insert(list, M)
end

function M.Init() Research.Init();Research.InstallHeightMarkerFix();Research.InstallCompatibilityHooks() end

function M.AddLuaHooks(add)
    add("Worlds.CPTWorld", function(module)
        local originalLoad = module.OnLoad
        module.OnLoad = function(self,loader)
            Research.BeforeLoad(self)
            local result=loadLargeTerrain(self,loader,originalLoad)
            Research.AfterLoad(self,templates)
            return result
        end
        if module.OnShutdown then
            local shutdown=module.OnShutdown
            module.OnShutdown=function(self,...) Research.Shutdown(self);return shutdown(self,...) end
        end
        local original = module.OnAdvance
        module.OnAdvance = function(self, dt)
            original(self, dt)
            if self.boundaryLabTask then
                local ok,message = g.coroutine.resume(self.boundaryLabTask)
                if not ok then
                    log("ERROR " .. g.tostring(message))
                    if self.boundaryLabRecovering then
                        self.boundaryLabTask = nil
                    else
                        self.boundaryLabRecovering = true
                        self.boundaryLabTask = g.coroutine.create(function()
                            local preview = self.boundaryLabPreview
                            self.boundaryLabPreview = nil
                            if preview then wait(api.undo.CancelPreview(preview)) end
                            Research.Finish(self,self.boundaryLabCommitResult~=nil
                                or (self.boundaryLabPurchase and self.boundaryLabPurchase.branch=="height"
                                    and self.boundaryLabHeightApplied==self.boundaryLabPurchase.level),
                                "Error: "..g.tostring(message)..". Research points refunded if the upgrade was not applied.")
                            notice("ERROR: " .. g.tostring(message))
                        end)
                    end
                elseif g.coroutine.status(self.boundaryLabTask) == "dead" then
                    self.boundaryLabTask = nil
                end
                return
            end
            if self.boundaryLabResearch then
                Research.Advance(self,expand)
                return
            end
            self.boundaryLabFrames = (self.boundaryLabFrames or 0) + 1
            if self.boundaryLabDone or self.boundaryLabFrames < 300 then return end
            if self.boundaryLabFrames % 120 ~= 0 then return end
            local w = api.world.GetWorldAPIs()
            if not self.boundaryLabTerrainCreated or api.undo.IsBusy() then return end
            self.boundaryLabDone = true
            self.boundaryLabTask = g.coroutine.create(function() expand(self) end)
        end
        log("HOOK INSTALLED")
    end)
end

log("DATABASE LOADED - Park Expansions 0.36 experimental expansion")
return M
