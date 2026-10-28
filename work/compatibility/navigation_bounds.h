#pragma once

// PC2 1.11.3.986758 NavigationWorld default initializer. The grid dimensions,
// spatial bounds and Detour budgets are derived by the original initializer.
// Redirect its two bounds-vector loads; do not edit shared engine constants.
static unsigned char* navigationConstants=nullptr;
static unsigned char* navigationImage=nullptr;
static uint8_t navigationReplacement[2][7]{};
static constexpr uint32_t navigationLoads[2]={0x164c50c,0x164c518};
static constexpr uint8_t navigationOriginal[2][7]={
    {0x0f,0x28,0x2d,0x0d,0x20,0xa9,0x01},
    {0x0f,0x28,0x1d,0xa1,0x1a,0xa9,0x01}
};

static unsigned char* allocateNavigationRange(uintptr_t probe,uintptr_t limit) {
    SYSTEM_INFO system{};GetSystemInfo(&system);
    const uintptr_t granularity=system.dwAllocationGranularity;
    probe=(probe+granularity-1)&~(granularity-1);
    while(probe<limit) {
        MEMORY_BASIC_INFORMATION info{};
        if(!VirtualQuery(reinterpret_cast<void*>(probe),&info,sizeof(info))) break;
        const uintptr_t end=reinterpret_cast<uintptr_t>(info.BaseAddress)+info.RegionSize;
        if(end<=probe) break;
        if(info.State==MEM_FREE) {
            uintptr_t candidate=(probe+granularity-1)&~(granularity-1);
            if(candidate+system.dwPageSize<=end && candidate+system.dwPageSize<=limit) {
                auto memory=static_cast<unsigned char*>(VirtualAlloc(reinterpret_cast<void*>(candidate),
                    system.dwPageSize,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE));
                if(memory) return memory;
            }
        }
        probe=end;
    }
    return nullptr;
}

static unsigned char* allocateNavigationConstants(unsigned char* nearAddress) {
    SYSTEM_INFO system{};GetSystemInfo(&system);
    const uintptr_t center=reinterpret_cast<uintptr_t>(nearAddress);
    const uintptr_t top=reinterpret_cast<uintptr_t>(system.lpMaximumApplicationAddress);
    const uintptr_t upper=(center>top-0x7fff0000)?top:center+0x7fff0000;
    if(auto memory=allocateNavigationRange(center+system.dwAllocationGranularity,upper)) return memory;
    // PC2 may reserve the entire forward RIP window. The backward window is
    // equally valid and must be searched before declaring allocation failure.
    const uintptr_t lower=center>0x7fff0000?center-0x7fff0000:system.dwAllocationGranularity;
    return allocateNavigationRange(lower,center);
}

static bool configureNavigationBounds(unsigned char* base,size_t size,std::string& error) {
    constexpr uint32_t begin=0x164c500,end=0x164c7f5;
    if(size<end) {error="Navigation initializer is outside the image.";return false;}
    if(navigationImage==base && navigationConstants) {
        for(int i=0;i<2;++i) if(std::memcmp(base+navigationLoads[i],navigationReplacement[i],7)) {
            error="Navigation instructions changed after initialization.";return false;
        }
        return true;
    }
    if(seaHash(base+begin,end-begin)!=0x376019742a709b97ULL) {
        error="Navigation initializer differs from the supported build.";return false;
    }
    for(int i=0;i<2;++i) if(std::memcmp(base+navigationLoads[i],navigationOriginal[i],7)) {
        error="Navigation bounds load signature mismatch.";return false;
    }
    auto constants=allocateNavigationConstants(base+begin);
    if(!constants) {error="Cannot allocate nearby navigation bounds constants.";return false;}
    float vectors[8]={-2048,-2048,-2048,-2048,2048,2048,2048,2048};
    std::memcpy(constants,vectors,sizeof(vectors));
    DWORD ignored=0;
    if(!VirtualProtect(constants,4096,PAGE_READONLY,&ignored)) {
        VirtualFree(constants,0,MEM_RELEASE);error="Cannot protect navigation constants.";return false;
    }
    uint8_t replacements[2][7];
    for(int i=0;i<2;++i) {
        auto delta=reinterpret_cast<intptr_t>(constants+i*16)-reinterpret_cast<intptr_t>(base+navigationLoads[i]+7);
        if(delta<INT32_MIN || delta>INT32_MAX) {
            VirtualFree(constants,0,MEM_RELEASE);error="Navigation constants are outside RIP range.";return false;
        }
        std::memcpy(replacements[i],navigationOriginal[i],7);
        int32_t relative=static_cast<int32_t>(delta);
        std::memcpy(replacements[i]+3,&relative,sizeof(relative));
    }
    // Both loads live on this single page; acquire permission before any write.
    DWORD old=0;auto page=base+0x164c000;
    if(!VirtualProtect(page,4096,PAGE_EXECUTE_READWRITE,&old)) {
        VirtualFree(constants,0,MEM_RELEASE);error="Cannot prepare navigation code page.";return false;
    }
    for(int i=0;i<2;++i) std::memcpy(base+navigationLoads[i],replacements[i],7);
    bool flushed=FlushInstructionCache(GetCurrentProcess(),base+begin,end-begin)!=0;
    if(!flushed) {
        for(int i=0;i<2;++i) std::memcpy(base+navigationLoads[i],navigationOriginal[i],7);
        FlushInstructionCache(GetCurrentProcess(),base+begin,end-begin);
        VirtualProtect(page,4096,old,&ignored);VirtualFree(constants,0,MEM_RELEASE);
        error="Navigation update failed; original instructions restored.";return false;
    }
    navigationImage=base;navigationConstants=constants;
    std::memcpy(navigationReplacement,replacements,sizeof(replacements));
    if(!VirtualProtect(page,4096,old,&ignored)) {
        error="Cannot restore navigation page protection.";return false;
    }
    return true;
}
