#pragma once

// CrowdSimulation owns a separate shared spatial grid, unrelated to Detour's
// NavigationWorld. Its constructor passes a fixed 1024 m span on both axes.
static unsigned char* crowdGridImage=nullptr;
static unsigned char* crowdGridConstant=nullptr;
static uint8_t crowdGridReplacement[8]{};
static bool configureCrowdGrid(unsigned char* base,size_t size,std::string& error) {
    constexpr uint32_t begin=0x96c870,end=0x96d5fd,load=0x96ce28;
    constexpr uint8_t original[8]={0xf3,0x0f,0x10,0x0d,0x08,0xb5,0x62,0x02};
    if(size<end) {error="Crowd constructor is outside the image.";return false;}
    if(crowdGridImage==base && crowdGridConstant) {
        if(!std::memcmp(base+load,crowdGridReplacement,8)) return true;
        error="Crowd grid instruction changed after initialization.";return false;
    }
    if(seaHash(base+begin,end-begin)!=0x0bb69904d3595496ULL || std::memcmp(base+load,original,8)) {
        error="Crowd constructor differs from the supported build.";return false;
    }
    auto memory=allocateNavigationConstants(base+load);
    if(!memory) {error="Cannot allocate nearby Crowd grid constant.";return false;}
    float width=4096.0f;std::memcpy(memory,&width,sizeof(width));
    DWORD ignored=0;
    if(!VirtualProtect(memory,4096,PAGE_READONLY,&ignored)) {
        VirtualFree(memory,0,MEM_RELEASE);error="Cannot protect Crowd grid constant.";return false;
    }
    auto delta=reinterpret_cast<intptr_t>(memory)-reinterpret_cast<intptr_t>(base+load+8);
    if(delta<INT32_MIN || delta>INT32_MAX) {
        VirtualFree(memory,0,MEM_RELEASE);error="Crowd constant is outside RIP range.";return false;
    }
    uint8_t replacement[8];std::memcpy(replacement,original,8);
    int32_t relative=static_cast<int32_t>(delta);std::memcpy(replacement+4,&relative,4);
    auto page=base+0x96c000;DWORD old=0;
    if(!VirtualProtect(page,4096,PAGE_EXECUTE_READWRITE,&old)) {
        VirtualFree(memory,0,MEM_RELEASE);error="Cannot prepare Crowd constructor page.";return false;
    }
    std::memcpy(base+load,replacement,8);
    if(!FlushInstructionCache(GetCurrentProcess(),base+load,8)) {
        std::memcpy(base+load,original,8);FlushInstructionCache(GetCurrentProcess(),base+load,8);
        VirtualProtect(page,4096,old,&ignored);VirtualFree(memory,0,MEM_RELEASE);
        error="Crowd update failed; original instruction restored.";return false;
    }
    crowdGridImage=base;crowdGridConstant=memory;
    std::memcpy(crowdGridReplacement,replacement,8);
    if(!VirtualProtect(page,4096,old,&ignored)) {
        error="Cannot restore Crowd constructor page protection.";return false;
    }
    return true;
}
