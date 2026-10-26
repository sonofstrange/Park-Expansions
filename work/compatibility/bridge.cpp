// Park Expansions: Lua C-module entry point and version-gated Sea raster fix.
// The game statically links Lua, so this module returns no Lua values and uses a
// read-only, version-gated reader for the four string arguments. Results travel
// through atomic Lua data files read by the game's existing loadfile function.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <filesystem>
#include <vector>
#include <cstdio>
#include "sea_raster.h"

namespace fs=std::filesystem;
static HANDLE worker=nullptr;

static bool readArgument(void* state,int index,char* output,size_t capacity) {
    // Observed public Lua 5.3 variant: L.top +0x10, L.ci +0x20,
    // CallInfo.func +0, TValue stride24/tag+16, TString bytes+24.
    // Reject non-strings and truncated arguments. SEH contains invalid pointers.
    __try {
        auto L=static_cast<unsigned char*>(state);
        auto ci=*reinterpret_cast<unsigned char**>(L+0x20);
        auto base=*reinterpret_cast<unsigned char**>(ci);
        auto top=*reinterpret_cast<unsigned char**>(L+0x10);
        auto value=base+24*index;
        if(index<1 || index>4 || value>=top || top-base>24*1024) return false;
        unsigned tag=*reinterpret_cast<unsigned*>(value+16);
        if((tag&0x0f)!=4) return false;
        auto text=*reinterpret_cast<unsigned char**>(value);
        size_t length=(tag&0x10)?*reinterpret_cast<size_t*>(text+16):text[11];
        if(!length || length>=capacity || std::memchr(text+24,0,length)) return false;
        std::memcpy(output,text+24,length);output[length]=0;
        return true;
    } __except(EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool supportedGame() {
    auto base=reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    auto dos=reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if(dos->e_magic!=IMAGE_DOS_SIGNATURE) return false;
    auto pe=reinterpret_cast<IMAGE_NT_HEADERS64*>(base+dos->e_lfanew);
    // Fail closed on a new executable build, before conversion or Sea changes.
    return pe->Signature==IMAGE_NT_SIGNATURE && pe->FileHeader.Machine==IMAGE_FILE_MACHINE_AMD64
        && pe->FileHeader.TimeDateStamp==0x6abfabee && pe->OptionalHeader.SizeOfImage==0x130a4000;
}

static std::wstring wide(const char* source) {
    int n=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,source,-1,nullptr,0);
    if(n<=0) throw std::runtime_error("Invalid UTF-8 request");
    std::wstring result(n,L'\0');
    MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,source,-1,result.data(),n);
    result.pop_back();return result;
}

static std::wstring quote(const std::wstring& value) {
    std::wstring result=L"\"";size_t slashes=0;
    for(auto c:value) {
        if(c==L'\\') { ++slashes;continue; }
        if(c==L'"') result.append(slashes*2+1,L'\\');
        else result.append(slashes,L'\\');
        slashes=0;result+=c;
    }
    result.append(slashes*2,L'\\');result+=L'"';return result;
}

static void atomicWrite(const fs::path& path,const std::string& text) {
    auto temp=path;temp+=L".native-tmp";
    HANDLE f=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(f==INVALID_HANDLE_VALUE) return;
    DWORD count=0;bool ok=WriteFile(f,text.data(),static_cast<DWORD>(text.size()),&count,nullptr) && count==text.size();
    CloseHandle(f);
    if(ok) MoveFileExW(temp.c_str(),path.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH);
}

extern "C" __declspec(dllexport) int Begin(void* L) {
    fs::path status;
    try {
        HMODULE module=nullptr;
        if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                              reinterpret_cast<LPCWSTR>(&Begin),&module)) return 0;
        wchar_t buffer[32768];DWORD n=GetModuleFileNameW(module,buffer,32768);
        if(!n || n==32768) return 0;
        auto compatibility=fs::path(buffer).parent_path();auto mod=compatibility.parent_path();
        auto cache=mod/L"AutoConversion";
        fs::create_directories(cache);
        bool supported=supportedGame();
        atomicWrite(cache/L"BridgeInfo.lua",supported?
            "return {version=32,supported=true}\n":
            "return {version=32,supported=false,message=\"Automatic conversion does not support this game build. Original park unchanged.\"}\n");
        if(!supported) return 0;
        char identifier[4096],name[4096],biome[128],nonce[128];
        if(!readArgument(L,1,identifier,sizeof(identifier)) || !readArgument(L,2,name,sizeof(name))
            || !readArgument(L,3,biome,sizeof(biome)) || !readArgument(L,4,nonce,sizeof(nonce))) return 0;
        bool hyphen=false;
        for(const char* p=nonce;*p;++p) {
            if(*p=='-' && !hyphen && p!=nonce && p[1]) hyphen=true;
            else if(*p<'0' || *p>'9') return 0;
        }
        if(!hyphen) return 0;
        status=cache/(L"State-"+wide(nonce)+L".lua");
        if(std::strcmp(identifier,"__initialize_sea__")==0) {
            std::string error;
            if(configureSeaRaster(reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr)),0x130a4000,error))
                atomicWrite(status,"return {status=\"sea_ready\",seaRaster=4096}\n");
            else atomicWrite(status,"return {status=\"error\",message=\""+error+"\"}\n");
            return 0;
        }
        if(worker && WaitForSingleObject(worker,0)==WAIT_TIMEOUT) {
            atomicWrite(status,"return {status=\"error\",message=\"Another conversion is still running. Try loading this park again shortly.\"}\n");return 0;
        }
        if(worker) { CloseHandle(worker);worker=nullptr; }
        auto executable=compatibility/L"AutoWorker/ParkExpansionsWorker.exe";
        auto command=quote(executable.wstring())+L" --mod-dir "+quote(mod.wstring())+
            L" --identifier "+quote(wide(identifier))+L" --name "+quote(wide(name))+
            L" --biome "+quote(wide(biome))+L" --nonce "+quote(wide(nonce));
        STARTUPINFOW startup{};startup.cb=sizeof(startup);startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=SW_HIDE;
        PROCESS_INFORMATION process{};
        atomicWrite(status,"return {status=\"working\",progress=0,message=\"Starting automatic conversion\"}\n");
        if(CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,
                          nullptr,mod.c_str(),&startup,&process)) {
            CloseHandle(process.hThread);worker=process.hProcess;
        } else {
            atomicWrite(status,"return {status=\"error\",message=\"Could not start the bundled conversion component. Original park unchanged.\"}\n");
        }
    } catch(...) {
        if(!status.empty()) atomicWrite(status,"return {status=\"error\",message=\"Automatic conversion could not start. Original park unchanged.\"}\n");
    }
    return 0;
}

#ifdef BRIDGE_TEST
#include <cassert>
extern "C" __declspec(dllexport) int TestSeaRaster(void* image,size_t length) {
    std::string error;
    return configureSeaRaster(static_cast<unsigned char*>(image),length,error)?1:0;
}
extern "C" __declspec(dllexport) int TestArgumentContract(void* state) {
    char value[4096];
    for(int index=1; index<=4; ++index) if(!readArgument(state,index,value,sizeof(value))) return 0;
    return 1;
}
int main() {
    unsigned char state[64]{},ci[32]{},stack[24*5]{},text[600]{};
    *reinterpret_cast<void**>(state+0x20)=ci;
    *reinterpret_cast<void**>(ci)=stack;
    *reinterpret_cast<void**>(state+0x10)=stack+sizeof(stack);
    *reinterpret_cast<void**>(stack+24)=text;
    *reinterpret_cast<unsigned*>(stack+24+16)=0x44;
    text[11]=5;std::memcpy(text+24,"hello",5);char out[1024];
    assert(readArgument(state,1,out,sizeof(out)) && std::string(out)=="hello");
    *reinterpret_cast<unsigned*>(stack+24+16)=0x54;
    *reinterpret_cast<size_t*>(text+16)=400;std::memset(text+24,'x',400);
    assert(readArgument(state,1,out,sizeof(out)) && std::strlen(out)==400);
    assert(!readArgument(state,1,out,200));
    *reinterpret_cast<unsigned*>(stack+24+16)=3;assert(!readArgument(state,1,out,sizeof(out)));
    assert(!readArgument(nullptr,1,out,sizeof(out)));
    assert(!readArgument(reinterpret_cast<void*>(1),1,out,sizeof(out)));
    assert(quote(L"a\\\"b\\")==L"\"a\\\\\\\"b\\\\\"");
    assert(!supportedGame());
    std::puts("PASS native argument reader, invalid pointers, string bounds, quoting and build guard");
}
#endif
