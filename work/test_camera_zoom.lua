local originalRequire=require
local hooks={}
api={world={GetWorldAPIs=function() return {} end}, debug={Trace=function()end}}
require=function(name)
    if name=='forgeutils.hookmanager' then
        return {
            AddHook=function(_,module,method,fn)
                hooks[module.."."..method]=fn
            end
        }
    end
    return originalRequire(name)
end

local R=assert(loadfile('work/boundarylab/Main/boundarylab.research.lua'))()
R.InstallCameraZoomFix()
require=originalRequire

assert(hooks["Components.Cameras.CameraModeManager.GetConfig"]~=nil, "Missing GetConfig hook")
assert(hooks["Components.Cameras.CameraModeManager.UpdateConfig"]~=nil, "Missing UpdateConfig hook")

local mockManager={
    tConfig={nZoomMaximum=300, nZoomMinimum=1.5}
}
local getConfigHook = hooks["Components.Cameras.CameraModeManager.GetConfig"]
local updateConfigHook = hooks["Components.Cameras.CameraModeManager.UpdateConfig"]

-- Test 1: Default 2K park with default zoom multiplier (2.0x -> 600m)
local world2k={parkExpansionsTerrainSize=2048}
R.BeforeLoad(world2k)
world2k.parkExpansionsConfig={CameraZoomMultiplier=2.0}

local cfg = getConfigHook(function(self) return self.tConfig end, mockManager)
assert(cfg.nZoomMaximum==600, "Expected 600m max zoom for 2.0x, got "..tostring(cfg.nZoomMaximum))

updateConfigHook(function(self) self.tConfig.nZoomMaximum=300 end, mockManager)
assert(mockManager.tConfig.nZoomMaximum==600, "UpdateConfig must apply 600m max zoom")

-- Test 2: 4K park without explicit config defaults to 2.5x (750m)
local world4k={parkExpansionsTerrainSize=4096}
R.BeforeLoad(world4k)
world4k.parkExpansionsConfig=nil
mockManager.tConfig.nZoomMaximum = 300
cfg = getConfigHook(function(self) return self.tConfig end, mockManager)
assert(cfg.nZoomMaximum==750, "Expected 750m max zoom for 4K default (2.5x), got "..tostring(cfg.nZoomMaximum))

-- Test 3: Custom multiplier 3.0x -> 900m
local worldCustom={parkExpansionsTerrainSize=4096}
R.BeforeLoad(worldCustom)
worldCustom.parkExpansionsConfig={CameraZoomMultiplier=3.0}
mockManager.tConfig.nZoomMaximum = 300
cfg = getConfigHook(function(self) return self.tConfig end, mockManager)
assert(cfg.nZoomMaximum==900, "Expected 900m max zoom for 3.0x, got "..tostring(cfg.nZoomMaximum))

print("PASS Camera Zoom Fix: hooks installed, default 2.0x (600m), 4K default 2.5x (750m), custom 3.0x (900m)")
