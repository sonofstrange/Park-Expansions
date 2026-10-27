// Park Expansions: Lua C-module entry point, Sea raster fix, and integrated background generator.
// The game statically links Lua, so this module returns no Lua values and uses a
// read-only, version-gated reader for arguments. Results travel through atomic Lua data files.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <intrin.h>
#include <cstdint>
#include <cstring>
#include <string>
#include <filesystem>
#include <vector>
#include <fstream>
#include <iostream>
#include <cassert>
#include <cmath>
#include <algorithm>
#include <functional>
#include <atomic>
#include "sea_raster.h"
#include "miniz.h"

#pragma comment(lib, "advapi32.lib")

namespace fs = std::filesystem;

static HANDLE worker_thread = nullptr;

// ---------------------------------------------------------------------------
// File & Utility Helpers
// ---------------------------------------------------------------------------

static void atomicWrite(const fs::path& path, const std::string& text) {
    auto temp = path; temp += L".native-tmp";
    HANDLE f = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    DWORD count = 0;
    bool ok = WriteFile(f, text.data(), static_cast<DWORD>(text.size()), &count, nullptr) && count == text.size();
    CloseHandle(f);
    if (ok) MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

static std::vector<uint8_t> read_file(const fs::path& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("Cannot open file: " + path.string());
    size_t size = f.tellg();
    f.seekg(0);
    std::vector<uint8_t> buf(size);
    f.read(reinterpret_cast<char*>(buf.data()), size);
    return buf;
}

static void write_file(const fs::path& path, const uint8_t* data, size_t size) {
    std::ofstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("Cannot create file: " + path.string());
    f.write(reinterpret_cast<const char*>(data), size);
}

// ---------------------------------------------------------------------------
// SHA-256 via Windows Cryptography API
// ---------------------------------------------------------------------------

static std::vector<uint8_t> sha256_raw(const uint8_t* data, size_t len) {
    HCRYPTPROV hProv = 0; HCRYPTHASH hHash = 0;
    if (!CryptAcquireContext(&hProv, NULL, NULL, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) return {};
    if (!CryptCreateHash(hProv, CALG_SHA_256, 0, 0, &hHash)) { CryptReleaseContext(hProv, 0); return {}; }
    CryptHashData(hHash, (BYTE*)data, (DWORD)len, 0);
    std::vector<uint8_t> hash(32); DWORD hashLen = 32;
    CryptGetHashParam(hHash, HP_HASHVAL, hash.data(), &hashLen, 0);
    CryptDestroyHash(hHash); CryptReleaseContext(hProv, 0);
    return hash;
}

static std::string sha256_hex_from_raw(const uint8_t* raw_digest, size_t len) {
    char hex[65];
    for (size_t i = 0; i < len; ++i) sprintf_s(hex + i * 2, 3, "%02x", raw_digest[i]);
    return std::string(hex);
}

// ---------------------------------------------------------------------------
// Lua Argument Parsing & Verification
// ---------------------------------------------------------------------------

static bool readArgument(void* state, int index, char* output, size_t capacity) {
    __try {
        auto L = static_cast<unsigned char*>(state);
        auto ci = *reinterpret_cast<unsigned char**>(L + 0x20);
        auto base = *reinterpret_cast<unsigned char**>(ci);
        auto top = *reinterpret_cast<unsigned char**>(L + 0x10);
        auto value = base + 24 * index;
        if (index < 1 || index > 4 || value >= top || top - base > 24 * 1024) return false;
        unsigned tag = *reinterpret_cast<unsigned*>(value + 16);
        if ((tag & 0x0f) != 4) return false;
        auto text = *reinterpret_cast<unsigned char**>(value);
        size_t length = (tag & 0x10) ? *reinterpret_cast<size_t*>(text + 16) : text[11];
        if (!length || length >= capacity || std::memchr(text + 24, 0, length)) return false;
        std::memcpy(output, text + 24, length); output[length] = 0;
        return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}

static bool supportedGame() {
    auto base = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto pe = reinterpret_cast<IMAGE_NT_HEADERS64*>(base + dos->e_lfanew);
    return pe->Signature == IMAGE_NT_SIGNATURE && pe->FileHeader.Machine == IMAGE_FILE_MACHINE_AMD64
        && pe->FileHeader.TimeDateStamp == 0x6abfabee && pe->OptionalHeader.SizeOfImage == 0x130a4000;
}

static std::wstring wide(const char* source) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, nullptr, 0);
    if (n <= 0) throw std::runtime_error("Invalid UTF-8 request");
    std::wstring result(n, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source, -1, result.data(), n);
    result.pop_back(); return result;
}

// ---------------------------------------------------------------------------
// Compression & Decompression
// ---------------------------------------------------------------------------

static std::vector<uint8_t> decompress_zlib(const uint8_t* in, size_t in_len, int wbits = -15) {
    z_stream strm{};
    if (inflateInit2(&strm, wbits) != Z_OK) throw std::runtime_error("inflateInit2 failed");
    strm.next_in = const_cast<uint8_t*>(in);
    strm.avail_in = static_cast<uInt>(in_len);

    std::vector<uint8_t> out;
    uint8_t temp[65536];
    int ret;
    do {
        strm.next_out = temp;
        strm.avail_out = sizeof(temp);
        ret = inflate(&strm, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) {
            inflateEnd(&strm);
            throw std::runtime_error("inflate failed: " + std::to_string(ret));
        }
        out.insert(out.end(), temp, temp + (sizeof(temp) - strm.avail_out));
    } while (ret != Z_STREAM_END);
    inflateEnd(&strm);
    return out;
}

static std::vector<uint8_t> compress_raw_deflate(const uint8_t* in, size_t in_len, int level = 6) {
    z_stream strm{};
    if (deflateInit2(&strm, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        throw std::runtime_error("deflateInit2 failed");
    }
    strm.next_in = const_cast<uint8_t*>(in);
    strm.avail_in = static_cast<uInt>(in_len);

    std::vector<uint8_t> out;
    uint8_t temp[65536];
    int ret;
    do {
        strm.next_out = temp;
        strm.avail_out = sizeof(temp);
        ret = deflate(&strm, Z_FINISH);
        out.insert(out.end(), temp, temp + (sizeof(temp) - strm.avail_out));
    } while (ret == Z_OK);
    deflateEnd(&strm);
    if (ret != Z_STREAM_END) throw std::runtime_error("deflate failed");
    return out;
}

static uint32_t read_uint(const uint8_t* data, size_t len, size_t& pos) {
    if (pos >= len) throw std::runtime_error("Unexpected EOF");
    uint8_t tag = data[pos++];
    if (tag < 0x40) return tag;
    if (tag >= 0xc0 && tag <= 0xef) {
        if (tag & 8) throw std::runtime_error("Negative scalar used as size");
        int n = (tag >> 4) - 11;
        if (pos + n > len) throw std::runtime_error("Unexpected EOF in scalar");
        uint32_t val = (tag & 7) << (8 * n);
        for (int i = 0; i < n; ++i) {
            val |= static_cast<uint32_t>(data[pos++]) << (8 * (n - 1 - i));
        }
        return val;
    }
    if (tag == 0xf0) {
        if (pos + 4 > len) throw std::runtime_error("Unexpected EOF in 0xf0 scalar");
        uint32_t val = 0;
        for (int i = 0; i < 4; ++i) {
            val = (val << 8) | data[pos++];
        }
        return val;
    }
    throw std::runtime_error("Unexpected scalar tag: " + std::to_string(tag));
}

static void put_uint(std::vector<uint8_t>& out, uint32_t value) {
    if (value < 64) {
        out.push_back(static_cast<uint8_t>(value));
        return;
    }
    for (int n = 1; n <= 3; ++n) {
        if (value < (1u << (8 * n + 3))) {
            uint8_t tag = static_cast<uint8_t>(((11 + n) << 4) | (value >> (8 * n)));
            out.push_back(tag);
            for (int i = n - 1; i >= 0; --i) {
                out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xff));
            }
            return;
        }
    }
    out.push_back(0xf0);
    for (int i = 3; i >= 0; --i) {
        out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xff));
    }
}

static std::vector<uint8_t> unpack_game_save(const std::vector<uint8_t>& data, std::vector<uint8_t>& preamble) {
    if (data.size() < 17) throw std::runtime_error("File too small");
    preamble.assign(data.begin(), data.begin() + 17);
    return decompress_zlib(data.data() + 17, data.size() - 17, -15);
}

// ---------------------------------------------------------------------------
// Voxel Volume Structures & Serialization
// ---------------------------------------------------------------------------

struct RootInfo {
    size_t tree_begin;
    size_t tree_end;
    size_t sample_begin;
    size_t sample_end;
    uint8_t sign;
};

struct Volume {
    uint32_t version;
    uint32_t shape[3];
    uint32_t block;
    uint32_t samples;
    std::vector<uint8_t> signs;
    std::vector<uint8_t> tree;
    std::vector<uint8_t> deltas;
    std::vector<uint8_t> materials;
    std::vector<RootInfo> roots;
};

static Volume parse_volume(const uint8_t* data, size_t len) {
    Volume v{};
    size_t p = 0;
    v.version = read_uint(data, len, p);
    assert(v.version == 5);
    for (int i = 0; i < 3; ++i) v.shape[i] = read_uint(data, len, p);
    v.block = read_uint(data, len, p);
    assert(v.block == 512);
    uint32_t scale = read_uint(data, len, p);
    assert(scale == 1);
    assert(data[p] == 0);
    p++;
    uint32_t root_count = v.shape[0] * v.shape[1] * v.shape[2];
    size_t signs_len = (root_count + 7) / 8;
    v.signs.assign(data + p, data + p + signs_len);
    p += signs_len;

    uint32_t tree_size = read_uint(data, len, p);
    v.samples = read_uint(data, len, p);
    v.tree.assign(data + p, data + p + tree_size);
    p += tree_size;
    v.deltas.assign(data + p, data + p + v.samples);
    p += v.samples;
    v.materials.assign(data + p, data + len);

    size_t index = 0;
    size_t samples = 0;
    auto walk = [&](auto& self, uint32_t side) -> void {
        assert(index < v.tree.size());
        uint8_t mask = v.tree[index++];
        if (side == 2) {
            samples += __popcnt(mask);
            return;
        }
        uint8_t flags = v.tree[index++];
        assert((flags & ~mask) == 0);
        for (int child = 0; child < 8; ++child) {
            if ((mask >> child) & 1) {
                self(self, side / 2);
            }
        }
    };

    for (uint32_t root = 0; root < root_count; ++root) {
        size_t a = index, b = samples;
        walk(walk, v.block);
        uint8_t sign = (v.signs[root / 8] >> (root % 8)) & 1;
        v.roots.push_back({a, index, b, samples, sign});
    }
    assert(index == v.tree.size());
    assert(samples == v.samples);
    return v;
}

static std::vector<uint8_t> decode_density(const uint8_t* deltas, size_t count) {
    std::vector<uint8_t> out(count);
    uint8_t acc = 0;
    for (size_t i = 0; i < count; ++i) {
        acc += deltas[i];
        out[i] = acc;
    }
    return out;
}

static std::vector<uint8_t> encode_density(const uint8_t* values, size_t count) {
    std::vector<uint8_t> out(count);
    uint8_t prev = 0;
    for (size_t i = 0; i < count; ++i) {
        out[i] = static_cast<uint8_t>(values[i] - prev);
        prev = values[i];
    }
    return out;
}

struct MaterialPart {
    std::vector<uint8_t> plane[3];
    std::vector<uint8_t> codes;
};

static std::vector<MaterialPart> extract_material_parts(const Volume& v) {
    size_t n = v.samples;
    const uint8_t* p0 = v.materials.data();
    const uint8_t* p1 = p0 + n;
    const uint8_t* p2 = p1 + n;
    const uint8_t* codes = p2 + n;

    std::vector<MaterialPart> parts;
    size_t cp = 0;
    for (const auto& r : v.roots) {
        MaterialPart mp;
        size_t count = r.sample_end - r.sample_begin;
        for (int i = 0; i < 3; ++i) {
            const uint8_t* src = (i == 0 ? p0 : (i == 1 ? p1 : p2)) + r.sample_begin;
            mp.plane[i].assign(src, src + count);
        }
        size_t code_bytes = count;
        for (size_t k = 0; k < count; ++k) {
            if (mp.plane[0][k] != 0 || mp.plane[1][k] != 0) code_bytes++;
        }
        mp.codes.assign(codes + cp, codes + cp + code_bytes);
        cp += code_bytes;
        parts.push_back(std::move(mp));
    }
    assert(cp == v.materials.size() - 3 * n);
    return parts;
}

// ---------------------------------------------------------------------------
// Save File Client Unpacking & Patching
// ---------------------------------------------------------------------------

struct ClientBlock {
    std::string name;
    size_t name_end;
    size_t version_end;
    size_t end;
};

struct ClientsInfo {
    size_t size_start;
    size_t size_end;
    std::vector<uint32_t> sizes;
    std::vector<ClientBlock> blocks;
};

static ClientsInfo parse_clients(const std::vector<uint8_t>& raw) {
    ClientsInfo info{};
    const char marker[] = "ClientSizes>";
    auto it = std::search(raw.begin(), raw.end(), marker, marker + 12);
    if (it == raw.end()) throw std::runtime_error("ClientSizes> not found");
    info.size_start = std::distance(raw.begin(), it) + 12;

    size_t pos = info.size_start;
    uint32_t count = read_uint(raw.data(), raw.size(), pos);
    for (uint32_t i = 0; i < count; ++i) {
        info.sizes.push_back(read_uint(raw.data(), raw.size(), pos));
    }
    info.size_end = pos;

    struct RawMatch {
        std::string name;
        size_t name_end;
    };
    std::vector<RawMatch> raw_matches;
    const uint8_t prefix1[] = {'H','e','a','d','e','r','C','l','i','e','n','t','>','>', 0xf3};
    const uint8_t prefix2[] = {'C','l','i','e','n','t','C','l','i','e','n','t','>','>', 0xf3};

    for (size_t i = info.size_end; i + 16 < raw.size(); ++i) {
        if (std::memcmp(raw.data() + i, prefix1, 15) == 0 || std::memcmp(raw.data() + i, prefix2, 15) == 0) {
            size_t name_start = i + 15;
            size_t name_end = name_start;
            while (name_end < raw.size() && raw[name_end] != 0 && (name_end - name_start) < 100) {
                name_end++;
            }
            if (name_end < raw.size() && raw[name_end] == 0 && name_end > name_start) {
                std::string name(reinterpret_cast<const char*>(raw.data() + name_start), name_end - name_start);
                raw_matches.push_back({name, name_end + 1});
                i = name_end;
            }
        }
    }
    if (raw_matches.size() != count) throw std::runtime_error("Client blocks count mismatch");

    for (uint32_t i = 0; i < count; ++i) {
        size_t vpos = raw_matches[i].name_end;
        uint32_t version = read_uint(raw.data(), raw.size(), vpos);
        size_t version_end = vpos;
        size_t block_end = version_end + info.sizes[i];

        if (block_end + 8 > raw.size() || std::memcmp(raw.data() + block_end, "<<Client", 8) != 0) {
            throw std::runtime_error("<<Client delimiter not found for block " + raw_matches[i].name);
        }
        info.blocks.push_back({raw_matches[i].name, raw_matches[i].name_end, version_end, block_end});
    }
    return info;
}

static std::vector<uint8_t> patch_client(const std::vector<uint8_t>& raw, const std::string& client_name, const std::vector<uint8_t>& replacement) {
    auto info = parse_clients(raw);
    int target_idx = -1;
    for (size_t i = 0; i < info.blocks.size(); ++i) {
        if (info.blocks[i].name == client_name) {
            target_idx = static_cast<int>(i);
            break;
        }
    }
    if (target_idx < 0) throw std::runtime_error("Client not found: " + client_name);
    const auto& block = info.blocks[target_idx];

    const uint8_t marker[] = {0x05, 0x02, 0x01, 0x02, 0xc2, 0x00, 0x01, 0x00};
    auto it = std::search(raw.begin() + block.version_end, raw.begin() + block.end, std::begin(marker), std::end(marker));
    if (it == raw.begin() + block.end) throw std::runtime_error("Marker not found in client block");
    size_t pos = std::distance(raw.begin(), it);

    info.sizes[target_idx] += static_cast<uint32_t>(replacement.size() - (block.end - pos));

    std::vector<uint8_t> result;
    result.insert(result.end(), raw.begin(), raw.begin() + info.size_start);
    put_uint(result, static_cast<uint32_t>(info.sizes.size()));
    for (uint32_t s : info.sizes) {
        put_uint(result, s);
    }
    result.insert(result.end(), raw.begin() + info.size_end, raw.begin() + pos);
    result.insert(result.end(), replacement.begin(), replacement.end());
    result.insert(result.end(), raw.begin() + block.end, raw.end());

    return result;
}

// ---------------------------------------------------------------------------
// Terrain Skirts & Height Sampling
// ---------------------------------------------------------------------------

struct StockTerrain {
    std::vector<float> height;
    std::vector<uint8_t> aux;
    uint32_t world_x = 0, world_z = 0;
    uint32_t nx = 0, nz = 0;
    float span = 0, offset = 0, water = 0;
    uint16_t material_lookup[65536]{};

    void load(const fs::path& skirt_path) {
        auto packed = read_file(skirt_path);
        assert(packed.size() > 4 && std::memcmp(packed.data(), "BHMP", 4) == 0);
        auto raw = decompress_zlib(packed.data() + 4, packed.size() - 4, -15);
        const uint8_t* p = raw.data();
        uint32_t version = *reinterpret_cast<const uint32_t*>(p); p += 4;
        world_x = *reinterpret_cast<const uint32_t*>(p); p += 4;
        world_z = *reinterpret_cast<const uint32_t*>(p); p += 4;
        nx = *reinterpret_cast<const uint32_t*>(p); p += 4;
        nz = *reinterpret_cast<const uint32_t*>(p); p += 4;
        uint32_t fmt = *reinterpret_cast<const uint32_t*>(p); p += 4;
        assert(version == 2 && fmt == 2 && nx == 2048 && nz == 2048);

        span = *reinterpret_cast<const float*>(p); p += 4;
        offset = *reinterpret_cast<const float*>(p); p += 4;
        water = *reinterpret_cast<const float*>(p); p += 4;

        uint8_t flag36 = *p;
        p = raw.data() + (37 + 4 * flag36);
        uint32_t height_count = *reinterpret_cast<const uint32_t*>(p); p += 4;
        assert(height_count == nx * nz * 2);

        height.resize(nx * nz);
        const uint16_t* u16 = reinterpret_cast<const uint16_t*>(p);
        float scale = span / 65535.0f;
        for (size_t i = 0; i < nx * nz; ++i) {
            height[i] = u16[i] * scale + offset;
        }
        p += height_count;

        uint32_t aux_count = *reinterpret_cast<const uint32_t*>(p); p += 4;
        assert(aux_count == nx * nz * 8);
        aux.assign(p, p + aux_count);
        p += aux_count;

        uint32_t mat_count = *reinterpret_cast<const uint32_t*>(p); p += 4;
        assert(mat_count == 16);

        bool seen[65536]{};
        for (size_t i = 0; i < nx * nz; ++i) {
            uint16_t mask = aux[i * 8] | (static_cast<uint16_t>(aux[i * 8 + 1]) << 8);
            if (!seen[mask]) {
                seen[mask] = true;
                std::vector<uint8_t> ids;
                for (int bit = 0; bit < 16; ++bit) {
                    if ((mask >> bit) & 1) ids.push_back(static_cast<uint8_t>(bit));
                }
                while (ids.size() < 4) {
                    for (int cand = 0; cand < 16; ++cand) {
                        bool has = false;
                        for (auto id : ids) if (id == cand) { has = true; break; }
                        if (!has) { ids.push_back(static_cast<uint8_t>(cand)); break; }
                    }
                }
                uint16_t code = ids[0] | (ids[1] << 4) | (ids[2] << 8) | (ids[3] << 12);
                material_lookup[mask] = code;
            }
        }
    }

    void sample_point(float x, float z, float& out_h, uint8_t weights[3], uint16_t& out_code) const {
        float u = (x / world_x + 0.5f) * nx;
        float v = (z / world_z + 0.5f) * nz;
        int ix = static_cast<int>(std::floor(u));
        int iz = static_cast<int>(std::floor(v));
        if (ix < 0) ix = 0; if (ix >= static_cast<int>(nx) - 1) ix = nx - 2;
        if (iz < 0) iz = 0; if (iz >= static_cast<int>(nz) - 1) iz = nz - 2;
        float a = u - ix;
        float b = v - iz;
        float h00 = height[iz * nx + ix];
        float h10 = height[iz * nx + ix + 1];
        float h01 = height[(iz + 1) * nx + ix];
        float h11 = height[(iz + 1) * nx + ix + 1];
        out_h = h00 * (1 - a) * (1 - b) + h10 * a * (1 - b) + h01 * (1 - a) * b + h11 * a * b;

        int ru = static_cast<int>(std::round(u));
        int rv = static_cast<int>(std::round(v));
        if (ru < 0) ru = 0; if (ru >= static_cast<int>(nx)) ru = nx - 1;
        if (rv < 0) rv = 0; if (rv >= static_cast<int>(nz)) rv = nz - 1;
        size_t aux_idx = (rv * nx + ru) * 8;
        uint16_t mask = aux[aux_idx] | (static_cast<uint16_t>(aux[aux_idx + 1]) << 8);
        out_code = material_lookup[mask];
        weights[0] = aux[aux_idx + 7];
        weights[1] = aux[aux_idx + 6];
        weights[2] = aux[aux_idx + 5];
    }
};

// ---------------------------------------------------------------------------
// Octree Generator
// ---------------------------------------------------------------------------

struct OctreeNodeResult {
    std::vector<uint8_t> tree;
    std::vector<uint8_t> density;
    std::vector<uint8_t> mat[4];
    uint8_t sign;
};

struct MipPyramid {
    std::vector<float> min_mip[10];
    std::vector<float> max_mip[10];
    std::vector<float> heights;
    std::vector<uint8_t> weights[3];
    std::vector<uint16_t> codes;
};

static void init_mip_pyramid(MipPyramid& mip, const StockTerrain& stock, int root_x, int root_z, int size) {
    mip.heights.resize(512 * 512);
    for (int i = 0; i < 3; ++i) mip.weights[i].resize(512 * 512);
    mip.codes.resize(512 * 512);

    int base_x = root_x * 512 - size / 2;
    int base_z = root_z * 512 - size / 2;

    for (int z = 0; z < 512; ++z) {
        for (int x = 0; x < 512; ++x) {
            float h;
            uint8_t w[3];
            uint16_t c;
            stock.sample_point(static_cast<float>(base_x + x), static_cast<float>(base_z + z), h, w, c);
            mip.heights[z * 512 + x] = h;
            mip.weights[0][z * 512 + x] = w[0];
            mip.weights[1][z * 512 + x] = w[1];
            mip.weights[2][z * 512 + x] = w[2];
            mip.codes[z * 512 + x] = c;
        }
    }

    mip.min_mip[0] = mip.heights;
    mip.max_mip[0] = mip.heights;

    for (int lvl = 1; lvl <= 9; ++lvl) {
        int prev_dim = 512 >> (lvl - 1);
        int cur_dim = 512 >> lvl;
        mip.min_mip[lvl].resize(cur_dim * cur_dim);
        mip.max_mip[lvl].resize(cur_dim * cur_dim);
        const auto& prev_min = mip.min_mip[lvl - 1];
        const auto& prev_max = mip.max_mip[lvl - 1];

        for (int z = 0; z < cur_dim; ++z) {
            for (int x = 0; x < cur_dim; ++x) {
                int z2 = z * 2;
                int x2 = x * 2;
                float mn = std::min({
                    prev_min[z2 * prev_dim + x2],
                    prev_min[(z2 + 1) * prev_dim + x2],
                    prev_min[z2 * prev_dim + x2 + 1],
                    prev_min[(z2 + 1) * prev_dim + x2 + 1]
                });
                float mx = std::max({
                    prev_max[z2 * prev_dim + x2],
                    prev_max[(z2 + 1) * prev_dim + x2],
                    prev_max[z2 * prev_dim + x2 + 1],
                    prev_max[(z2 + 1) * prev_dim + x2 + 1]
                });
                mip.min_mip[lvl][z * cur_dim + x] = mn;
                mip.max_mip[lvl][z * cur_dim + x] = mx;
            }
        }
    }
}

static OctreeNodeResult build_octree_node(const MipPyramid& mip, int side, int x, int y, int z) {
    int lvl = 0;
    while ((1 << lvl) < side) lvl++;
    int dim = 512 >> lvl;
    int mx = x / side;
    int mz = z / side;
    float low = mip.min_mip[lvl][mz * dim + mx];
    float high = mip.max_mip[lvl][mz * dim + mx];

    if (y + side <= static_cast<int>(std::floor(low)) - 1) {
        OctreeNodeResult res;
        if (side == 2) res.tree.push_back(0);
        else { res.tree.push_back(0); res.tree.push_back(0); }
        res.sign = 0;
        return res;
    }
    if (y >= static_cast<int>(std::ceil(high)) + 2) {
        OctreeNodeResult res;
        if (side == 2) res.tree.push_back(0);
        else { res.tree.push_back(0); res.tree.push_back(0); }
        res.sign = 1;
        return res;
    }

    uint8_t sign = static_cast<uint8_t>(y >= mip.heights[z * 512 + x]);

    if (side == 2) {
        OctreeNodeResult res;
        res.tree.push_back(0xff);
        res.sign = sign;
        res.density.resize(8);
        for (int i = 0; i < 8; ++i) {
            int vx = x + (i >> 2);
            int vy = y + ((i >> 1) & 1);
            int vz = z + (i & 1);
            float diff = (vy - mip.heights[vz * 512 + vx]) * 127.0f;
            int rounded = static_cast<int>(std::round(diff));
            if (rounded < -127) rounded = -127;
            if (rounded > 127) rounded = 127;
            res.density[i] = static_cast<uint8_t>(rounded & 0xff);
        }

        for (int p = 0; p < 3; ++p) {
            res.mat[p].resize(8);
            for (int i = 0; i < 8; ++i) {
                int vx = x + (i >> 2);
                int vz = z + (i & 1);
                res.mat[p][i] = mip.weights[p][vz * 512 + vx];
            }
        }
        for (int i = 0; i < 8; ++i) {
            int vx = x + (i >> 2);
            int vz = z + (i & 1);
            uint16_t code = mip.codes[vz * 512 + vx];
            bool two_bytes = (res.mat[0][i] != 0) || (res.mat[1][i] != 0);
            if (two_bytes) {
                res.mat[3].push_back(static_cast<uint8_t>(code & 0xff));
                res.mat[3].push_back(static_cast<uint8_t>((code >> 8) & 0xff));
            } else {
                res.mat[3].push_back(static_cast<uint8_t>(code & 0xff));
            }
        }
        return res;
    }

    int h = side / 2;
    OctreeNodeResult children[8];
    uint8_t flags = 0;
    for (int i = 0; i < 8; ++i) {
        children[i] = build_octree_node(mip, h, x + (i >> 2) * h, y + ((i >> 1) & 1) * h, z + (i & 1) * h);
        if (children[i].sign) flags |= (1 << i);
    }

    OctreeNodeResult res;
    res.sign = sign;
    res.tree.push_back(255);
    res.tree.push_back(flags);
    for (int i = 0; i < 8; ++i) {
        res.tree.insert(res.tree.end(), children[i].tree.begin(), children[i].tree.end());
        res.density.insert(res.density.end(), children[i].density.begin(), children[i].density.end());
        for (int c = 0; c < 4; ++c) {
            res.mat[c].insert(res.mat[c].end(), children[i].mat[c].begin(), children[i].mat[c].end());
        }
    }
    return res;
}

// ---------------------------------------------------------------------------
// Dynamic Scenery Backdrop Extraction & Placement
// ---------------------------------------------------------------------------

struct SceneryInstance { float x, y, z, angle; };
struct SceneryGroup { std::string resource; std::vector<SceneryInstance> instances; };

static const char* CLUSTERS[] = {
    "NAT_Tree_Conifer_Larch_European_Cluster_01",
    "NAT_Tree_Conifer_Larch_European_Cluster_02",
    "NAT_Tree_Conifer_Pine_Aleppo_Cluster_01",
    "NAT_Tree_Conifer_Pine_Aleppo_Cluster_02",
    "NAT_Tree_Broadleaf_Olive_Cluster_01",
    "NAT_Tree_Broadleaf_Olive_Cluster_02",
    "NAT_Bush_Creosote_Flowerless_Cluster_01",
};

static bool is_cluster(const std::string& name) {
    for (const char* c : CLUSTERS) if (name == c) return true;
    return false;
}

struct BakedHeights {
    std::vector<float> data;
    uint32_t nx, nz, wx, wz;
};

static BakedHeights read_baked_heights(const fs::path& path) {
    auto packed = read_file(path);
    if (packed.size() < 4 || std::memcmp(packed.data(), "BHMP", 4) != 0) throw std::runtime_error("Not BHMP");
    auto raw = decompress_zlib(packed.data() + 4, packed.size() - 4, -15);
    uint32_t version, wx, wz, nx, nz, fmt;
    std::memcpy(&version, raw.data(), 4);
    std::memcpy(&wx, raw.data() + 4, 4);
    std::memcpy(&wz, raw.data() + 8, 4);
    std::memcpy(&nx, raw.data() + 12, 4);
    std::memcpy(&nz, raw.data() + 16, 4);
    std::memcpy(&fmt, raw.data() + 20, 4);
    float span, offset;
    std::memcpy(&span, raw.data() + 24, 4);
    std::memcpy(&offset, raw.data() + 28, 4);
    size_t p = 37 + 4 * raw[36];
    uint32_t byte_count;
    std::memcpy(&byte_count, raw.data() + p, 4);
    const uint16_t* u16 = reinterpret_cast<const uint16_t*>(raw.data() + p + 4);
    BakedHeights bh;
    bh.nx = nx; bh.nz = nz; bh.wx = wx; bh.wz = wz;
    bh.data.resize(nx * nz);
    float scale = span / 65535.0f;
    for (size_t i = 0; i < nx * nz; ++i) bh.data[i] = static_cast<float>(u16[i]) * scale + offset;
    return bh;
}

static float sample_height_grid(const std::vector<float>& height, uint32_t nx, uint32_t nz, float world_x, float world_z, float x, float z) {
    float u = (x / world_x + 0.5f) * static_cast<float>(nx);
    float v = (z / world_z + 0.5f) * static_cast<float>(nz);
    int ix = static_cast<int>(std::floor(u));
    int iz = static_cast<int>(std::floor(v));
    if (ix < 0 || ix >= static_cast<int>(nx) - 1 || iz < 0 || iz >= static_cast<int>(nz) - 1)
        throw std::runtime_error("Sample out of bounds");
    float a = u - static_cast<float>(ix);
    float b = v - static_cast<float>(iz);
    float h00 = height[iz * nx + ix];
    float h01 = height[iz * nx + (ix + 1)];
    float h10 = height[(iz + 1) * nx + ix];
    float h11 = height[(iz + 1) * nx + (ix + 1)];
    return (h00 * (1.0f - a) * (1.0f - b) + h01 * a * (1.0f - b) + h10 * (1.0f - a) * b + h11 * a * b);
}

static std::vector<SceneryGroup> extract_placements(const fs::path& ovl_path, const fs::path* baked_path, uint32_t size) {
    auto data = read_file(ovl_path);
    uint32_t names_size; std::memcpy(&names_size, data.data() + 16, 4);
    uint16_t mimes; std::memcpy(&mimes, data.data() + 30, 2);
    uint32_t files; std::memcpy(&files, data.data() + 32, 4);
    uint32_t archive_names_size; std::memcpy(&archive_names_size, data.data() + 80, 4);
    uint32_t triplets; std::memcpy(&triplets, data.data() + 92, 4);
    uint32_t aux; std::memcpy(&aux, data.data() + 24, 4);
    size_t p = 144 + names_size + mimes * 32 + ((triplets * 3 + 3) & ~3) + files * 12 + archive_names_size;

    uint32_t pools; uint16_t datas, pool_groups;
    uint32_t buffer_groups, buffers, fragments, roots, read_start, set_size, compressed_size;
    uint64_t uncompressed_size;
    uint32_t pools_start, pools_end, ovs_offset;
    std::memcpy(&pools, data.data() + p + 12, 4);
    std::memcpy(&datas, data.data() + p + 16, 2);
    std::memcpy(&pool_groups, data.data() + p + 18, 2);
    std::memcpy(&buffer_groups, data.data() + p + 20, 4);
    std::memcpy(&buffers, data.data() + p + 24, 4);
    std::memcpy(&fragments, data.data() + p + 28, 4);
    std::memcpy(&roots, data.data() + p + 32, 4);
    std::memcpy(&read_start, data.data() + p + 36, 4);
    std::memcpy(&set_size, data.data() + p + 40, 4);
    std::memcpy(&compressed_size, data.data() + p + 44, 4);
    std::memcpy(&uncompressed_size, data.data() + p + 48, 8);
    std::memcpy(&pools_start, data.data() + p + 56, 4);
    std::memcpy(&pools_end, data.data() + p + 60, 4);
    std::memcpy(&ovs_offset, data.data() + p + 64, 4);

    size_t eof = p + 68 + aux * 12 + 8;
    auto raw = decompress_zlib(data.data() + eof, compressed_size, 15);
    size_t pool_table = pool_groups * 4;
    std::vector<uint32_t> pool_sizes(pools);
    for (uint32_t i = 0; i < pools; ++i) std::memcpy(&pool_sizes[i], raw.data() + pool_table + i * 32 + 8, 4);
    size_t buffer_table = pool_table + pools * 32 + datas * 32;
    size_t root_table = buffer_table + buffers * 8 + buffer_groups * 32;
    uint32_t matched_pool_id = 0, matched_offset = 0;
    for (uint32_t i = 0; i < roots; ++i) {
        uint32_t hash, pid, off;
        std::memcpy(&hash, raw.data() + root_table + i * 16 + 4, 4);
        std::memcpy(&pid, raw.data() + root_table + i * 16 + 8, 4);
        std::memcpy(&off, raw.data() + root_table + i * 16 + 12, 4);
        if (hash == 3059885504u) { matched_pool_id = pid; matched_offset = off; break; }
    }
    size_t pool_start = root_table + roots * 16 + set_size;
    size_t pool_offset_sum = 0;
    for (uint32_t i = 0; i < matched_pool_id; ++i) pool_offset_sum += pool_sizes[i];
    size_t header = pool_start + pool_offset_sum + matched_offset;
    uint64_t byte_count; float scale;
    std::memcpy(&byte_count, raw.data() + header + 8, 8);
    std::memcpy(&scale, raw.data() + header + 32, 4);
    size_t all_pools_sum = 0;
    for (uint32_t s : pool_sizes) all_pools_sum += s;
    size_t body_start = pool_start + all_pools_sum + 600;
    const uint8_t* body = raw.data() + body_start;

    uint64_t groups_offset, groups_count, names_offset, names_count;
    std::memcpy(&groups_offset, raw.data() + header + 72, 8);
    std::memcpy(&groups_count, raw.data() + header + 80, 8);
    std::memcpy(&names_offset, raw.data() + header + 104, 8);
    std::memcpy(&names_count, raw.data() + header + 112, 8);

    std::vector<std::string> names;
    for (uint64_t i = 0; i < names_count; ++i) {
        uint64_t str_start; std::memcpy(&str_start, body + names_offset + i * 8, 8);
        std::string s;
        for (uint64_t k = str_start; k < byte_count && body[k] != 0; ++k) s.push_back((char)body[k]);
        names.push_back(s);
    }

    std::vector<float> original_height;
    bool has_original_height = false;
    if (baked_path != nullptr) {
        uint64_t layer_offset, layer_count;
        std::memcpy(&layer_offset, raw.data() + header + 40, 8);
        std::memcpy(&layer_count, raw.data() + header + 48, 8);
        if (layer_count == 1) {
            uint64_t name_id, dtype, height_offset, height_bytes;
            std::memcpy(&name_id, body + layer_offset, 8);
            std::memcpy(&dtype, body + layer_offset + 8, 8);
            std::memcpy(&height_offset, body + layer_offset + 16, 8);
            std::memcpy(&height_bytes, body + layer_offset + 24, 8);
            if (name_id < names.size() && names[name_id] == "height" && dtype == 2 && height_bytes == 2048 * 2048 * 4) {
                original_height.resize(2048 * 2048);
                std::memcpy(original_height.data(), body + height_offset, height_bytes);
                has_original_height = true;
            }
        }
    }

    std::vector<SceneryGroup> groups;
    float limit = static_cast<float>(size / 2 - 4);
    for (uint64_t i = 0; i < groups_count; ++i) {
        uint64_t grp_off, grp_cnt, name_id;
        std::memcpy(&grp_off, body + groups_offset + i * 32, 8);
        std::memcpy(&grp_cnt, body + groups_offset + i * 32 + 8, 8);
        std::memcpy(&name_id, body + groups_offset + i * 32 + 16, 8);
        if (name_id >= names.size()) continue;
        std::string resource = names[name_id];
        const std::string s1 = "_SkirtNoShadow", s2 = "_Skirt";
        if (resource.size() >= s1.size() && resource.compare(resource.size() - s1.size(), s1.size(), s1) == 0) resource.resize(resource.size() - s1.size());
        else if (resource.size() >= s2.size() && resource.compare(resource.size() - s2.size(), s2.size(), s2) == 0) resource.resize(resource.size() - s2.size());
        if (is_cluster(resource)) resource = "PE_" + resource;

        SceneryGroup grp;
        grp.resource = resource;
        for (uint64_t j = 0; j < grp_cnt; ++j) {
            float x, y, z, angle;
            std::memcpy(&x, body + grp_off + j * 16, 4);
            std::memcpy(&y, body + grp_off + j * 16 + 4, 4);
            std::memcpy(&z, body + grp_off + j * 16 + 8, 4);
            std::memcpy(&angle, body + grp_off + j * 16 + 12, 4);
            float edge = std::max(std::abs(x), std::abs(z));
            if (edge >= 512.0f && edge < limit) grp.instances.push_back({x, y, z, angle});
        }
        if (!grp.instances.empty()) groups.push_back(std::move(grp));
    }

    if (baked_path != nullptr && has_original_height) {
        auto bh = read_baked_heights(*baked_path);
        float orig_span = 2048.0f * scale;
        for (auto& grp : groups) {
            for (auto& inst : grp.instances) {
                float orig_g = sample_height_grid(original_height, 2048, 2048, orig_span, orig_span, inst.x, inst.z);
                float baked_g = sample_height_grid(bh.data, bh.nx, bh.nz, (float)bh.wx, (float)bh.wz, inst.x, inst.z);
                inst.y += (baked_g - orig_g);
            }
        }
    }
    return groups;
}

static void ensure_scenery_decor(const fs::path& game_dir, const fs::path& out_folder, const std::string& name, uint32_t size) {
    fs::path decor_path = out_folder / (name + ".decor.lua");
    if (fs::exists(decor_path)) return;

    std::string biome = name;
    const std::string suffix = "Sandbox";
    if (biome.size() > suffix.size() && biome.substr(biome.size() - suffix.size()) == suffix) {
        biome = biome.substr(0, biome.size() - suffix.size());
    }

    fs::path ovl_path = game_dir / "Win64/ovldata/Content0/Worlds" / (biome + "World") / (biome + "World.ovl");
    fs::path baked_path = game_dir / "TerrainSkirts" / name / (name + ".bakedHeightMap");

    if (!fs::exists(ovl_path) || !fs::exists(baked_path)) {
        atomicWrite(decor_path, "return {version=1,source=\"0000000000000000000000000000000000000000000000000000000000000000\",groups={}}\n");
        return;
    }

    auto ovl_bytes = read_file(ovl_path);
    auto baked_bytes = read_file(baked_path);
    auto d1 = sha256_raw(ovl_bytes.data(), ovl_bytes.size());
    auto d2 = sha256_raw(baked_bytes.data(), baked_bytes.size());
    std::vector<uint8_t> combined;
    combined.insert(combined.end(), d1.begin(), d1.end());
    combined.insert(combined.end(), d2.begin(), d2.end());
    auto final_d = sha256_raw(combined.data(), combined.size());
    std::string fingerprint = sha256_hex_from_raw(final_d.data(), final_d.size());

    auto groups = extract_placements(ovl_path, &baked_path, size);

    std::string text = "return {version=1,source=\"" + fingerprint + "\",groups={\n";
    for (const auto& grp : groups) {
        text += "{resource=\"" + grp.resource + "\",instances={\n";
        for (const auto& inst : grp.instances) {
            char buf[128];
            snprintf(buf, sizeof(buf), "{%.6f,%.6f,%.6f,%.6f},\n", inst.x, inst.y, inst.z, inst.angle);
            text += buf;
        }
        text += "}},\n";
    }
    text += "}}\n";
    atomicWrite(decor_path, text);
}

// ---------------------------------------------------------------------------
// Background Map Preparation
// ---------------------------------------------------------------------------

static void prepare_map(const fs::path& mod_dir, const std::string& biome_arg, const std::string& nonce) {
    fs::path cache = mod_dir / "AutoConversion";
    fs::create_directories(cache);
    int progress_seq = 0;

    auto progress = [&](int pct, const std::string& msg) {
        progress_seq++;
        fs::path p = cache / ("Progress-" + nonce + "-" + std::to_string(progress_seq) + ".lua");
        atomicWrite(p, "return {status=\"working\",progress=" + std::to_string(pct) + ",message=\"" + msg + "\"}\n");
    };

    auto finish = [&](const std::string& status, const std::string& filename, int size, bool cached, const std::string& err = "") {
        fs::path p = cache / ("Result-" + nonce + ".lua");
        if (status == "map_ready") {
            atomicWrite(p, "return {status=\"map_ready\",progress=100,filename=\"" + filename +
                "\",terrainSize=" + std::to_string(size) + ",cached=" + (cached ? "true" : "false") + "}\n");
        } else {
            atomicWrite(p, "return {status=\"error\",progress=0,message=\"" + err + "\"}\n");
        }
    };

    try {
        std::string raw_biome = biome_arg;
        std::transform(raw_biome.begin(), raw_biome.end(), raw_biome.begin(), ::tolower);
        int size = 2048;
        std::string base_biome = raw_biome;
        auto colon = raw_biome.find(':');
        if (colon != std::string::npos) {
            base_biome = raw_biome.substr(0, colon);
            size = std::stoi(raw_biome.substr(colon + 1));
        }

        std::string name;
        if (base_biome == "temperate") name = "TemperateSandbox";
        else if (base_biome == "tropical") name = "TropicalSandbox";
        else if (base_biome == "taiga") name = "TaigaSandbox";
        else if (base_biome == "mediterranean") name = "MediterraneanSandbox";
        else throw std::runtime_error("Unsupported biome: " + base_biome);

        fs::path folder_name = (size == 4096) ? "Maps4096" : "Maps";
        fs::path out_folder = mod_dir / folder_name;
        fs::create_directories(out_folder);

        fs::path bin_out = out_folder / (name + ".bin");
        fs::path trn_out = out_folder / (name + ".trn");
        fs::path gen_out = out_folder / (name + ".generation.json");
        fs::path decor_out = out_folder / (name + ".decor.lua");

        fs::path game_dir = mod_dir.parent_path().parent_path().parent_path();

        if (fs::exists(bin_out) && fs::exists(trn_out) && fs::exists(gen_out) && fs::exists(decor_out)) {
            finish("map_ready", name + ".bin", size, true);
            return;
        }

        progress(5, "Reading original terrain");

        fs::path skirt_path = game_dir / "TerrainSkirts" / name / (name + ".bakedHeightMap");
        fs::path src_bin = game_dir / "Parks/Sandbox" / (name + ".bin");
        fs::path src_trn = game_dir / "Parks/Sandbox" / (name + ".trn");

        if (!fs::exists(skirt_path) || !fs::exists(src_bin) || !fs::exists(src_trn)) {
            throw std::runtime_error("Original game files not found");
        }

        std::vector<uint8_t> preamble_bin, preamble_trn;
        auto raw_bin = unpack_game_save(read_file(src_bin), preamble_bin);
        auto raw_trn = unpack_game_save(read_file(src_trn), preamble_trn);

        auto info_bin = parse_clients(raw_bin);
        auto client_it = std::find_if(info_bin.blocks.begin(), info_bin.blocks.end(), [](const ClientBlock& b) { return b.name == "VoxelTerrain"; });
        if (client_it == info_bin.blocks.end()) throw std::runtime_error("VoxelTerrain not found in source bin");

        const uint8_t marker[] = {0x05, 0x02, 0x01, 0x02, 0xc2, 0x00, 0x01, 0x00};
        auto it = std::search(raw_bin.begin() + client_it->version_end, raw_bin.begin() + client_it->end, std::begin(marker), std::end(marker));
        if (it == raw_bin.begin() + client_it->end) throw std::runtime_error("Terrain marker not found in source bin");

        Volume old_vol = parse_volume(&*it, std::distance(it, raw_bin.begin() + client_it->end));
        auto old_densities = decode_density(old_vol.deltas.data(), old_vol.deltas.size());
        auto old_mats = extract_material_parts(old_vol);

        StockTerrain stock;
        stock.load(skirt_path);

        int width = size / 512;
        int inner = width / 2 - 1;
        int total = width * 9 * width;

        std::vector<uint8_t> signs((total + 7) / 8, 0);
        std::vector<std::vector<uint8_t>> chunks(total);
        std::vector<std::vector<uint8_t>> densities(total);
        std::vector<std::vector<uint8_t>> materials[4];
        for (int c = 0; c < 4; ++c) materials[c].resize(total);

        // Precompute MipPyramids for all (x, z) columns
        std::vector<MipPyramid> mips(width * width);
        for (int z = 0; z < width; ++z) {
            for (int x = 0; x < width; ++x) {
                if (!(x >= inner && x <= inner + 1 && z >= inner && z <= inner + 1)) {
                    init_mip_pyramid(mips[z * width + x], stock, x, z, size);
                }
            }
        }

        for (int z = 0; z < width; ++z) {
            for (int y = 0; y < 9; ++y) {
                for (int x = 0; x < width; ++x) {
                    int index = (z * 9 + y) * width + x;
                    if (index % 10 == 0) {
                        progress(5 + (index * 70) / total, "Preparing terrain: " + std::to_string(index + 1) + "/" + std::to_string(total));
                    }

                    std::vector<uint8_t> tree, density;
                    std::vector<uint8_t> mat[4];
                    uint8_t sign = 0;

                    if (y == 4 && (x == inner || x == inner + 1) && (z == inner || z == inner + 1)) {
                        int source = (z - inner) * 2 + (x - inner);
                        const auto& r = old_vol.roots[source];
                        tree.assign(old_vol.tree.begin() + r.tree_begin, old_vol.tree.begin() + r.tree_end);
                        density.assign(old_densities.begin() + r.sample_begin, old_densities.begin() + r.sample_end);
                        for (int c = 0; c < 3; ++c) mat[c] = old_mats[source].plane[c];
                        mat[3] = old_mats[source].codes;
                        sign = r.sign;
                    } else if ((x == inner || x == inner + 1) && (z == inner || z == inner + 1) && y < 4) {
                        tree = {0, 0};
                        sign = 0;
                    } else if ((x == inner || x == inner + 1) && (z == inner || z == inner + 1) && y > 4) {
                        tree = {0, 0};
                        sign = 1;
                    } else {
                        auto res = build_octree_node(mips[z * width + x], 512, 0, (y - 2) * 512 - 1280, 0);
                        tree = std::move(res.tree);
                        density = std::move(res.density);
                        for (int c = 0; c < 4; ++c) mat[c] = std::move(res.mat[c]);
                        sign = res.sign;
                    }

                    signs[index / 8] |= (sign << (index % 8));
                    chunks[index] = std::move(tree);
                    densities[index] = std::move(density);
                    for (int c = 0; c < 4; ++c) materials[c][index] = std::move(mat[c]);
                }
            }
        }

        std::vector<uint8_t> all_tree;
        for (const auto& c : chunks) all_tree.insert(all_tree.end(), c.begin(), c.end());

        std::vector<uint8_t> all_density;
        for (const auto& d : densities) all_density.insert(all_density.end(), d.begin(), d.end());

        std::vector<uint8_t> all_mat;
        for (int c = 0; c < 4; ++c) {
            for (const auto& m : materials[c]) all_mat.insert(all_mat.end(), m.begin(), m.end());
        }

        std::vector<uint8_t> replacement;
        put_uint(replacement, 5);
        put_uint(replacement, width);
        put_uint(replacement, 9);
        put_uint(replacement, width);
        put_uint(replacement, 512);
        put_uint(replacement, 1);
        replacement.push_back(0);
        replacement.insert(replacement.end(), signs.begin(), signs.end());
        put_uint(replacement, static_cast<uint32_t>(all_tree.size()));
        put_uint(replacement, static_cast<uint32_t>(all_density.size()));
        replacement.insert(replacement.end(), all_tree.begin(), all_tree.end());

        auto enc_density = encode_density(all_density.data(), all_density.size());
        replacement.insert(replacement.end(), enc_density.begin(), enc_density.end());
        replacement.insert(replacement.end(), all_mat.begin(), all_mat.end());

        progress(80, "Writing " + name + ".bin");
        auto patched_bin = patch_client(raw_bin, "VoxelTerrain", replacement);
        auto comp_bin = compress_raw_deflate(patched_bin.data(), patched_bin.size(), 6);
        std::vector<uint8_t> final_bin;
        final_bin.insert(final_bin.end(), preamble_bin.begin(), preamble_bin.end());
        final_bin.insert(final_bin.end(), comp_bin.begin(), comp_bin.end());

        progress(85, "Writing " + name + ".trn");
        auto patched_trn = patch_client(raw_trn, "VoxelTerrainUnderlay", replacement);
        auto comp_trn = compress_raw_deflate(patched_trn.data(), patched_trn.size(), 6);
        std::vector<uint8_t> final_trn;
        final_trn.insert(final_trn.end(), preamble_trn.begin(), preamble_trn.end());
        final_trn.insert(final_trn.end(), comp_trn.begin(), comp_trn.end());

        write_file(bin_out, final_bin.data(), final_bin.size());
        write_file(trn_out, final_trn.data(), final_trn.size());

        float h600, h750, h900;
        uint8_t dummy_w[3]; uint16_t dummy_c;
        stock.sample_point(600, 0, h600, dummy_w, dummy_c);
        stock.sample_point(750, 0, h750, dummy_w, dummy_c);
        stock.sample_point(900, 0, h900, dummy_w, dummy_c);

        std::ofstream fchk(out_folder / (name + ".checks.lua"));
        fchk << "Heights = {[\"" << (name + ".bin") << "\"] = {[600]=" << h600
             << ", [750]=" << h750 << ", [900]=" << h900
             << ", [\"600\"]=" << h600 << ", [\"750\"]=" << h750 << ", [\"900\"]=" << h900 << "}}\n";
        fchk.close();

        progress(92, "Extracting scenery backdrop");
        ensure_scenery_decor(game_dir, out_folder, name, size);

        std::ofstream fgen(gen_out);
        fgen << "{\n  \"version\": 36,\n  \"size\": " << size << ",\n  \"cached\": true\n}\n";
        fgen.close();

        finish("map_ready", name + ".bin", size, false);
    } catch (const std::exception& e) {
        finish("error", "", 0, false, e.what());
    }
}

// ---------------------------------------------------------------------------
// Lua C-Module Export: Begin
// ---------------------------------------------------------------------------

struct BackgroundWorkerTask {
    fs::path mod_dir;
    std::string biome;
    std::string nonce;
};

static DWORD WINAPI BackgroundWorkerProc(LPVOID param) {
    auto* task = static_cast<BackgroundWorkerTask*>(param);
    prepare_map(task->mod_dir, task->biome, task->nonce);
    delete task;
    return 0;
}

extern "C" __declspec(dllexport) int Begin(void* L) {
    fs::path status;
    try {
        HMODULE module = nullptr;
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(&Begin), &module)) return 0;
        wchar_t buffer[32768]; DWORD n = GetModuleFileNameW(module, buffer, 32768);
        if (!n || n == 32768) return 0;
        auto compatibility = fs::path(buffer).parent_path();
        auto mod = compatibility.parent_path();
        auto cache = mod / L"AutoConversion";
        fs::create_directories(cache);
        bool supported = supportedGame();
        atomicWrite(cache / L"BridgeInfo.lua", supported ?
            "return {version=32,supported=true}\n" :
            "return {version=32,supported=false,message=\"Automatic conversion does not support this game build. Original park unchanged.\"}\n");
        if (!supported) return 0;

        char identifier[4096], name[4096], biome[128], nonce[128];
        if (!readArgument(L, 1, identifier, sizeof(identifier)) || !readArgument(L, 2, name, sizeof(name))
            || !readArgument(L, 3, biome, sizeof(biome)) || !readArgument(L, 4, nonce, sizeof(nonce))) return 0;

        bool hyphen = false;
        for (const char* p = nonce; *p; ++p) {
            if (*p == '-' && !hyphen && p != nonce && p[1]) hyphen = true;
            else if (*p < '0' || *p > '9') return 0;
        }
        if (!hyphen) return 0;

        status = cache / (L"State-" + wide(nonce) + L".lua");

        if (std::strcmp(identifier, "__initialize_sea__") == 0) {
            std::string error;
            if (configureSeaRaster(reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr)), 0x130a4000, error))
                atomicWrite(status, "return {status=\"sea_ready\",seaRaster=4096}\n");
            else atomicWrite(status, "return {status=\"error\",message=\"" + error + "\"}\n");
            return 0;
        }

        if (worker_thread) {
            DWORD exit_code = 0;
            if (GetExitCodeThread(worker_thread, &exit_code) && exit_code == STILL_ACTIVE) {
                atomicWrite(status, "return {status=\"error\",message=\"Another conversion is still running. Try loading this park again shortly.\"}\n");
                return 0;
            }
            CloseHandle(worker_thread);
            worker_thread = nullptr;
        }

        if (std::strcmp(identifier, "__prepare_map__") == 0) {
            atomicWrite(status, "return {status=\"working\",progress=0,message=\"Starting background terrain preparation\"}\n");
            auto* task = new BackgroundWorkerTask{mod, biome, nonce};
            worker_thread = CreateThread(nullptr, 0, BackgroundWorkerProc, task, 0, nullptr);
            if (!worker_thread) {
                delete task;
                atomicWrite(status, "return {status=\"error\",message=\"Could not start background worker thread.\"}\n");
            }
            return 0;
        }

    } catch (...) {
        if (!status.empty()) atomicWrite(status, "return {status=\"error\",message=\"Automatic conversion could not start. Original park unchanged.\"}\n");
    }
    return 0;
}

#ifdef BRIDGE_TEST
extern "C" __declspec(dllexport) int TestSeaRaster(void* image, size_t length) {
    std::string error;
    return configureSeaRaster(static_cast<unsigned char*>(image), length, error) ? 1 : 0;
}
extern "C" __declspec(dllexport) int TestArgumentContract(void* state) {
    char value[4096];
    for (int index = 1; index <= 4; ++index) if (!readArgument(state, index, value, sizeof(value))) return 0;
    return 1;
}
int main() {
    unsigned char state[64]{}, ci[32]{}, stack[24 * 5]{}, text[600]{};
    *reinterpret_cast<void**>(state + 0x20) = ci;
    *reinterpret_cast<void**>(ci) = stack;
    *reinterpret_cast<void**>(state + 0x10) = stack + sizeof(stack);
    *reinterpret_cast<void**>(stack + 24) = text;
    *reinterpret_cast<unsigned*>(stack + 24 + 16) = 0x44;
    text[11] = 5; std::memcpy(text + 24, "hello", 5); char out[1024];
    assert(readArgument(state, 1, out, sizeof(out)) && std::string(out) == "hello");
    *reinterpret_cast<unsigned*>(stack + 24 + 16) = 0x54;
    *reinterpret_cast<size_t*>(text + 16) = 400; std::memset(text + 24, 'x', 400);
    assert(readArgument(state, 1, out, sizeof(out)) && std::strlen(out) == 400);
    assert(!readArgument(state, 1, out, 200));
    *reinterpret_cast<unsigned*>(stack + 24 + 16) = 3; assert(!readArgument(state, 1, out, sizeof(out)));
    assert(!readArgument(nullptr, 1, out, sizeof(out)));
    assert(!readArgument(reinterpret_cast<void*>(1), 1, out, sizeof(out)));
    assert(!supportedGame());
    std::puts("PASS native argument reader, invalid pointers, string bounds, and build guard");
    return 0;
}
#endif
