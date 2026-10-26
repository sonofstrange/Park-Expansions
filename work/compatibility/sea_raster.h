#pragma once
#include "sea_raster_plan.h"

static uint64_t seaHash(const unsigned char* first, size_t length) {
    uint64_t h=14695981039346656037ULL;
    for(size_t i=0;i<length;++i) h=(h^first[i])*1099511628211ULL;
    return h;
}

// Called once from database initialization, before native park/Sea creation.
// Keep the 4096 raster for the whole process, including later 1024/2048 parks.
// No detours, injected calls, shared float-constant changes or disk EXE edits.
static bool configureSeaRaster(unsigned char* base, size_t size, std::string& error) {
    bool original=true,replacement=true;
    for(const auto& g:seaGuards) {
        if(g.end>size || g.begin>=g.end) { error="Sea code range is unavailable.";return false; }
        auto hash=seaHash(base+g.begin,g.end-g.begin);
        original&=hash==g.original;replacement&=hash==g.replacement;
    }
    if(replacement) return true;
    if(!original) { error="Sea code differs from the supported game build; 4K loading disabled.";return false; }
    for(const auto& p:seaPatches) {
        if(p.rva+p.length>size || std::memcmp(base+p.rva,p.original,p.length)) {
            error="Sea instruction verification failed; 4K loading disabled.";return false;
        }
    }
    SYSTEM_INFO system{};GetSystemInfo(&system);
    struct Page { unsigned char* address; DWORD protection; };
    std::vector<Page> pages;
    for(const auto& g:seaGuards) {
        for(size_t rva=g.begin/system.dwPageSize*system.dwPageSize;rva<g.end;rva+=system.dwPageSize) {
            DWORD old=0;
            if(!VirtualProtect(base+rva,system.dwPageSize,PAGE_EXECUTE_READWRITE,&old)) {
                for(const auto& page:pages) { DWORD ignored;VirtualProtect(page.address,system.dwPageSize,page.protection,&ignored); }
                error="Could not prepare Sea code pages; no instructions changed.";return false;
            }
            pages.push_back({base+rva,old});
        }
    }
    // No writes occur until all signatures and page permissions are ready.
    for(const auto& p:seaPatches) std::memcpy(base+p.rva,p.replacement,p.length);
    bool ok=true;
    for(const auto& g:seaGuards) {
        ok&=seaHash(base+g.begin,g.end-g.begin)==g.replacement;
        ok&=FlushInstructionCache(GetCurrentProcess(),base+g.begin,g.end-g.begin)!=0;
    }
    if(!ok) {
        for(const auto& p:seaPatches) std::memcpy(base+p.rva,p.original,p.length);
        for(const auto& g:seaGuards) FlushInstructionCache(GetCurrentProcess(),base+g.begin,g.end-g.begin);
        error="Sea code update did not validate; original instructions restored.";
    }
    bool restored=true;
    for(const auto& page:pages) {
        DWORD ignored;restored&=VirtualProtect(page.address,system.dwPageSize,page.protection,&ignored)!=0;
    }
    if(!restored) { error="Sea code page protection could not be restored.";return false; }
    return ok;
}
