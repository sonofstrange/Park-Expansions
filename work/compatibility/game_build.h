#pragma once
// An update is allowed only after its code ranges and Lua ABI are verified.
// Each patch additionally verifies its complete function hash before writing.
static bool updatedGameBuild=false;
static bool latestGameBuild=false;
static bool selectGameBuild(uint32_t timestamp,uint32_t imageSize) {
    latestGameBuild=false;
    if(timestamp==0x6ae8f335 && imageSize==0x12343000) {latestGameBuild=true;updatedGameBuild=true;return true;}
    if(timestamp==0x6ae11c9a && imageSize==0x12187000) {updatedGameBuild=true;return true;}
    if(timestamp==0x6abfabee && imageSize==0x130a4000) {updatedGameBuild=false;return true;}
    return false;
}
