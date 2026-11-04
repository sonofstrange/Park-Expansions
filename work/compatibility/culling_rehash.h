#pragma once

// Static culling node insertion caches a bucket pointer before recursively
// inserting its parent. That recursive insertion may rehash/free the buckets.
// Refresh the bucket immediately before linking the new node into the table.
static unsigned char* cullingImage=nullptr;
static unsigned char* cullingHelper=nullptr;
static uint8_t cullingReplacement[16]{};
static bool configureCullingRehash(unsigned char* base,size_t size,std::string& error) {
    const uint32_t begin=updatedGameBuild?0x1a63160:0x1a15020,end=begin+0x4ba,site=begin+0x3c8;
    const uint32_t hashBegin=updatedGameBuild?0x1a61ad0:0x1a13990,hashReturn=hashBegin+0xcc;
    constexpr uint8_t original[16]={0x48,0x8b,0x07,0x48,0x89,0x06,0x48,0x89,0x37,0x49,0x8b,0x8e,0x30,0x01,0x00,0x00};
    constexpr size_t replaced=16;
    if(size<end){error="Culling insertion is outside the image.";return false;}
    if(cullingImage==base && cullingHelper) {
        if(!std::memcmp(base+site,cullingReplacement,16))return true;
        error="Culling insertion changed after initialization.";return false;
    }
    if(seaHash(base+begin,end-begin)!=(updatedGameBuild?0xb21adae2a7c1f69bULL:0xfa9ebdc7970dd59eULL)
        || seaHash(base+hashBegin,hashReturn-hashBegin+1)!=0x99ed5fc50ec41cddULL
        || std::memcmp(base+site,original,16)) {
        error="Culling insertion differs from the supported build.";return false;
    }
    auto memory=allocateNavigationConstants(base+site);
    if(!memory){error="Cannot allocate nearby culling helper.";return false;}
    std::vector<uint8_t> code={0x48,0x8d,0x4e,0x08}; // rcx = new node's key
    // Position-independent leaf arithmetic: no branches, calls, stack writes,
    // nonvolatile-register changes, or external data references in the hash.
    code.insert(code.end(),base+hashBegin,base+hashReturn);
    const uint8_t refresh[]={0x89,0xc0,0x33,0xd2,
        0x49,0xf7,0xb6,0x30,0x01,0x00,0x00, // unsigned hash % CURRENT bucket count
        0x49,0x8b,0x86,0x28,0x01,0x00,0x00, // CURRENT bucket allocation
        0x48,0x8d,0x3c,0xd0}; // rdi = current bucket address
    code.insert(code.end(),std::begin(refresh),std::end(refresh));
    code.insert(code.end(),base+site,base+site+replaced);
    code.push_back(0xc3);
    // A real CALL/RET to a leaf helper keeps x64 stack unwinding valid without
    // a trampoline that borrows the original function's partially applied frame.
    const auto delta=reinterpret_cast<intptr_t>(memory)-reinterpret_cast<intptr_t>(base+site+5);
    if(delta<INT32_MIN || delta>INT32_MAX){VirtualFree(memory,0,MEM_RELEASE);error="Culling helper is outside call range.";return false;}
    std::memcpy(memory,code.data(),code.size());DWORD ignored=0;
    if(!VirtualProtect(memory,4096,PAGE_EXECUTE_READ,&ignored)
        || !FlushInstructionCache(GetCurrentProcess(),memory,code.size())) {
        VirtualFree(memory,0,MEM_RELEASE);error="Cannot finalize culling helper.";return false;
    }
    uint8_t replacement[16];std::memset(replacement,0x90,sizeof(replacement));replacement[0]=0xe8;
    const int32_t relative=static_cast<int32_t>(delta);std::memcpy(replacement+1,&relative,4);
    auto page=base+(site&~uint32_t(4095));DWORD old=0;
    if(!VirtualProtect(page,4096,PAGE_EXECUTE_READWRITE,&old)){
        VirtualFree(memory,0,MEM_RELEASE);error="Cannot prepare culling code page.";return false;
    }
    uint8_t saved[16];std::memcpy(saved,base+site,16);std::memcpy(base+site,replacement,16);
    if(!FlushInstructionCache(GetCurrentProcess(),base+site,16)) {
        std::memcpy(base+site,saved,16);FlushInstructionCache(GetCurrentProcess(),base+site,16);
        VirtualProtect(page,4096,old,&ignored);VirtualFree(memory,0,MEM_RELEASE);
        error="Culling update failed; original instructions restored.";return false;
    }
    cullingImage=base;cullingHelper=memory;std::memcpy(cullingReplacement,replacement,16);
    if(!VirtualProtect(page,4096,old,&ignored)){error="Cannot restore culling code page protection.";return false;}
    return true;
}
