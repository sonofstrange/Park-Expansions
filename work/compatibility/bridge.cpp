// Park Expansions: Lua C-module entry point, Sea raster fix, and integrated background generator.
// The game statically links Lua, so this module returns no Lua values and uses a
// read-only, version-gated reader for arguments. Results travel through atomic Lua data files.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
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

static std::vector<uint8_t> decompress_zlib(const uint8_t* in, size_t in_len, int wbits = 15) {
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
    throw std::runtime_error("Unexpected scalar tag");
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

static std::vector<uint8_t> decode_density(const uint8_t* data, size_t len) {
    std::vector<uint8_t> values;
    size_t pos = 0;
    uint8_t current = 0;
    while (pos < len) {
        uint32_t rle = read_uint(data, len, pos);
        if (rle > 0) {
            values.insert(values.end(), rle, current);
        }
        if (pos < len) {
            current = (current + data[pos++]) & 0xff;
            values.push_back(current);
        }
    }
    return values;
}

static std::vector<uint8_t> encode_density(const uint8_t* values, size_t len) {
    std::vector<uint8_t> out;
    size_t i = 0;
    uint8_t current = 0;
    while (i < len) {
        size_t start = i;
        while (i < len && values[i] == current) ++i;
        put_uint(out, static_cast<uint32_t>(i - start));
        if (i < len) {
            uint8_t diff = (values[i] - current) & 0xff;
            out.push_back(diff);
            current = values[i];
            ++i;
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Save File Client Unpacking & Patching
// ---------------------------------------------------------------------------

struct ClientBlock {
    std::string name;
    size_t start, version_end, end;
};

struct ClientArchiveInfo {
    size_t header_len;
    std::vector<ClientBlock> blocks;
};

static std::vector<uint8_t> unpack_game_save(const std::vector<uint8_t>& data, std::vector<uint8_t>& preamble) {
    if (data.size() < 17) throw std::runtime_error("File too small");
    preamble.assign(data.begin(), data.begin() + 17);
    return decompress_zlib(data.data() + 17, data.size() - 17, -15);
}

static ClientArchiveInfo parse_clients(const std::vector<uint8_t>& raw) {
    ClientArchiveInfo info;
    size_t p = 0;
    uint32_t count = read_uint(raw.data(), raw.size(), p);
    info.header_len = p;
    for (uint32_t i = 0; i < count; ++i) {
        size_t start = p;
        uint32_t name_len = read_uint(raw.data(), raw.size(), p);
        std::string name(reinterpret_cast<const char*>(raw.data() + p), name_len);
        p += name_len;
        size_t version_end = p;
        p += 2;
        uint32_t block_len = read_uint(raw.data(), raw.size(), p);
        p += block_len;
        info.blocks.push_back({name, start, version_end, p});
    }
    return info;
}

static std::vector<uint8_t> patch_client(const std::vector<uint8_t>& raw, const std::string& target_client, const std::vector<uint8_t>& replacement_body) {
    auto info = parse_clients(raw);
    const ClientBlock* target = nullptr;
    for (const auto& b : info.blocks) {
        if (b.name == target_client) { target = &b; break; }
    }
    if (!target) throw std::runtime_error("Target client not found: " + target_client);

    std::vector<uint8_t> out;
    out.insert(out.end(), raw.begin(), raw.begin() + target->start);
    put_uint(out, static_cast<uint32_t>(target_client.size()));
    out.insert(out.end(), target_client.begin(), target_client.end());
    out.insert(out.end(), raw.begin() + target->version_end, raw.begin() + target->version_end + 2);
    put_uint(out, static_cast<uint32_t>(replacement_body.size()));
    out.insert(out.end(), replacement_body.begin(), replacement_body.end());
    out.insert(out.end(), raw.begin() + target->end, raw.end());
    return out;
}

// ---------------------------------------------------------------------------
// Voxel Octree & Volume Parsing
// ---------------------------------------------------------------------------

struct OctreeNode {
    uint8_t child_mask;
    uint8_t leaf_mask;
    uint16_t child_offset;
    uint16_t leaf_offset;
};

struct VoxelTerrain {
    OctreeNode root;
    std::vector<OctreeNode> nodes;
    std::vector<uint8_t> leaves;
    std::vector<uint8_t> materials[4];
};

struct Volume {
    uint32_t width_chunks, height_layers, depth_chunks, chunk_size, scale;
    std::vector<uint8_t> signs;
    std::vector<uint8_t> tree;
    std::vector<uint8_t> deltas;
    std::vector<uint8_t> materials;
};

static Volume parse_volume(const uint8_t* data, size_t len) {
    Volume v;
    size_t p = 8;
    v.width_chunks = read_uint(data, len, p);
    v.height_layers = read_uint(data, len, p);
    v.depth_chunks = read_uint(data, len, p);
    v.chunk_size = read_uint(data, len, p);
    v.scale = read_uint(data, len, p);
    p += 1;
    size_t sign_bytes = (v.width_chunks * v.height_layers * v.depth_chunks + 7) / 8;
    v.signs.assign(data + p, data + p + sign_bytes);
    p += sign_bytes;
    uint32_t tree_bytes = read_uint(data, len, p);
    uint32_t delta_bytes = read_uint(data, len, p);
    v.tree.assign(data + p, data + p + tree_bytes);
    p += tree_bytes;
    v.deltas.assign(data + p, data + p + delta_bytes);
    p += delta_bytes;
    v.materials.assign(data + p, data + len);
    return v;
}

struct MaterialParts {
    std::vector<uint8_t> parts[4];
};

static MaterialParts extract_material_parts(const Volume& vol) {
    MaterialParts mp;
    size_t p = 0;
    size_t count = 0;
    for (uint8_t b : vol.tree) {
        if (b & 1) count += ((b >> 1) & 0x7f) + 1;
    }
    for (int part = 0; part < 4; ++part) {
        size_t remaining = count;
        while (remaining > 0) {
            uint32_t run = read_uint(vol.materials.data(), vol.materials.size(), p);
            put_uint(mp.parts[part], run);
            remaining -= run;
            if (remaining > 0) {
                mp.parts[part].push_back(vol.materials[p++]);
                remaining--;
            }
        }
    }
    return mp;
}

// ---------------------------------------------------------------------------
// Terrain Skirts & Height Sampling
// ---------------------------------------------------------------------------

struct StockTerrain {
    std::vector<float> heights;
    std::vector<uint8_t> weights[3];
    std::vector<uint16_t> classes;
    uint32_t nx = 0, nz = 0;
    float span = 0.0f, offset = 0.0f;

    void load(const fs::path& skirt_path) {
        auto packed = read_file(skirt_path);
        auto raw = decompress_zlib(packed.data() + 4, packed.size() - 4, -15);
        nx = *reinterpret_cast<const uint32_t*>(raw.data() + 12);
        nz = *reinterpret_cast<const uint32_t*>(raw.data() + 16);
        span = *reinterpret_cast<const float*>(raw.data() + 24);
        offset = *reinterpret_cast<const float*>(raw.data() + 28);
        size_t p = 37 + 4 * raw[36];
        const uint16_t* u16 = reinterpret_cast<const uint16_t*>(raw.data() + p + 4);
        size_t total = nx * nz;
        heights.resize(total);
        for (size_t i = 0; i < total; ++i) {
            heights[i] = static_cast<float>(u16[i]) * (span / 65535.0f) + offset;
        }
        p += 4 + total * 2;
        for (int i = 0; i < 3; ++i) {
            weights[i].assign(raw.data() + p + 4, raw.data() + p + 4 + total);
            p += 4 + total;
        }
        const uint16_t* cls = reinterpret_cast<const uint16_t*>(raw.data() + p + 4);
        classes.assign(cls, cls + total);
    }

    void sample_point(float x, float z, float& h, uint8_t w[3], uint16_t& cls) const {
        float u = (x / 2048.0f + 0.5f) * static_cast<float>(nx);
        float v = (z / 2048.0f + 0.5f) * static_cast<float>(nz);
        int ix = std::clamp(static_cast<int>(std::floor(u)), 0, static_cast<int>(nx) - 2);
        int iz = std::clamp(static_cast<int>(std::floor(v)), 0, static_cast<int>(nz) - 2);
        float a = u - static_cast<float>(ix);
        float b = v - static_cast<float>(iz);
        size_t idx00 = iz * nx + ix;
        size_t idx01 = idx00 + 1;
        size_t idx10 = (iz + 1) * nx + ix;
        size_t idx11 = idx10 + 1;
        h = heights[idx00] * (1 - a) * (1 - b) + heights[idx01] * a * (1 - b) +
            heights[idx10] * (1 - a) * b + heights[idx11] * a * b;
        for (int i = 0; i < 3; ++i) {
            float fw = weights[i][idx00] * (1 - a) * (1 - b) + weights[i][idx01] * a * (1 - b) +
                       weights[i][idx10] * (1 - a) * b + weights[i][idx11] * a * b;
            w[i] = static_cast<uint8_t>(std::clamp(static_cast<int>(std::round(fw)), 0, 255));
        }
        cls = classes[idx00];
    }
};

struct MipPyramid {
    std::vector<float> levels[9];
    float min_h, max_h;
};

static void init_mip_pyramid(MipPyramid& mip, const StockTerrain& stock, int cx, int cz, int size) {
    float origin_x = -size / 2.0f + cx * 512.0f;
    float origin_z = -size / 2.0f + cz * 512.0f;
    mip.levels[0].resize(513 * 513);
    float h_min = 1e9f, h_max = -1e9f;
    uint8_t dummy_w[3]; uint16_t dummy_c;
    for (int z = 0; z <= 512; ++z) {
        float pz = origin_z + z;
        for (int x = 0; x <= 512; ++x) {
            float px = origin_x + x;
            float h;
            stock.sample_point(px, pz, h, dummy_w, dummy_c);
            mip.levels[0][z * 513 + x] = h;
            if (h < h_min) h_min = h;
            if (h > h_max) h_max = h;
        }
    }
    mip.min_h = h_min; mip.max_h = h_max;
    for (int lvl = 1; lvl <= 8; ++lvl) {
        int dim = (512 >> lvl) + 1;
        int prev_dim = (512 >> (lvl - 1)) + 1;
        mip.levels[lvl].resize(dim * dim);
        for (int z = 0; z < dim; ++z) {
            for (int x = 0; x < dim; ++x) {
                float v = (mip.levels[lvl - 1][(z * 2) * prev_dim + (x * 2)] +
                           mip.levels[lvl - 1][(z * 2) * prev_dim + (x * 2 + 1)] +
                           mip.levels[lvl - 1][(z * 2 + 1) * prev_dim + (x * 2)] +
                           mip.levels[lvl - 1][(z * 2 + 1) * prev_dim + (x * 2 + 1)]) * 0.25f;
                mip.levels[lvl][z * dim + x] = v;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Octree Generator
// ---------------------------------------------------------------------------

struct GeneratedChunk {
    std::vector<uint8_t> tree;
    std::vector<uint8_t> density;
    std::vector<uint8_t> mat[4];
};

static void build_octree_node(int level, float x, float y, float z, float size,
                              const MipPyramid& mip, const StockTerrain& stock,
                              GeneratedChunk& chunk) {
    if (level == 8) {
        uint8_t dummy_w[3]; uint16_t cls;
        float h;
        stock.sample_point(x + 0.5f, z + 0.5f, h, dummy_w, cls);
        float d = (y + 0.5f) - h;
        uint8_t d_byte = static_cast<uint8_t>(std::clamp(static_cast<int>(std::round(d * 16.0f + 128.0f)), 0, 255));
        chunk.tree.push_back(1);
        chunk.density.push_back(d_byte);
        chunk.mat[0].push_back(dummy_w[0]);
        chunk.mat[1].push_back(dummy_w[1]);
        chunk.mat[2].push_back(dummy_w[2]);
        chunk.mat[3].push_back(cls & 0xff);
        return;
    }

    float half = size * 0.5f;
    uint8_t child_mask = 0;
    uint8_t leaf_mask = 0;

    for (int child = 0; child < 8; ++child) {
        float cx = x + ((child & 1) ? half : 0.0f);
        float cy = y + ((child & 2) ? half : 0.0f);
        float cz = z + ((child & 4) ? half : 0.0f);

        if (cy + half < mip.min_h - 4.0f) {
            leaf_mask |= (1 << child);
        } else if (cy > mip.max_h + 4.0f) {
            // Air: neither child nor solid leaf
        } else {
            child_mask |= (1 << child);
        }
    }

    if (child_mask == 0 && leaf_mask == 0) {
        chunk.tree.push_back(0); // Uniform air
        return;
    }
    if (child_mask == 0 && leaf_mask == 0xff) {
        chunk.tree.push_back(2); // Uniform solid
        return;
    }

    chunk.tree.push_back(0x80 | (child_mask & 0x7f));
    chunk.tree.push_back(leaf_mask);

    for (int child = 0; child < 8; ++child) {
        if (child_mask & (1 << child)) {
            float cx = x + ((child & 1) ? half : 0.0f);
            float cy = y + ((child & 2) ? half : 0.0f);
            float cz = z + ((child & 4) ? half : 0.0f);
            build_octree_node(level + 1, cx, cy, cz, half, mip, stock, chunk);
        }
    }
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
        const uint8_t marker[] = {0x05, 0x02, 0x01, 0x02, 0xc2, 0x00, 0x01, 0x00};
        auto it = std::search(raw_bin.begin() + client_it->version_end, raw_bin.begin() + client_it->end, std::begin(marker), std::end(marker));
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

        std::vector<MipPyramid> mips(width * width);
        for (int z = 0; z < width; ++z) {
            for (int x = 0; x < width; ++x) {
                if (!(x >= inner && x <= inner + 1 && z >= inner && z <= inner + 1)) {
                    init_mip_pyramid(mips[z * width + x], stock, x, z, size);
                }
            }
        }

        size_t old_leaf_ptr = 0;
        size_t old_chunk_idx = 0;
        size_t old_mat_ptr = 0;

        int done_chunks = 0;
        for (int z = 0; z < width; ++z) {
            for (int y = 0; y < 9; ++y) {
                for (int x = 0; x < width; ++x) {
                    int idx = (z * 9 + y) * width + x;
                    if (x >= inner && x <= inner + 1 && z >= inner && z <= inner + 1) {
                        int byte_idx = old_chunk_idx / 8;
                        int bit_idx = old_chunk_idx % 8;
                        if (old_vol.signs[byte_idx] & (1 << bit_idx)) {
                            signs[idx / 8] |= (1 << (idx % 8));
                        }
                        size_t p = 0;
                        size_t tree_start = p;
                        std::function<void()> skip_tree = [&]() {
                            uint8_t b = old_vol.tree[tree_start + p++];
                            if (b & 0x80) {
                                uint8_t cm = b & 0x7f;
                                uint8_t lm = old_vol.tree[tree_start + p++];
                                for (int ch = 0; ch < 8; ++ch) {
                                    if (cm & (1 << ch)) skip_tree();
                                }
                            }
                        };
                        skip_tree();
                        size_t tree_len = p;
                        chunks[idx].assign(old_vol.tree.begin() + tree_start, old_vol.tree.begin() + tree_start + tree_len);

                        size_t leaves_in_chunk = 0;
                        for (uint8_t b : chunks[idx]) {
                            if (b & 1) leaves_in_chunk += ((b >> 1) & 0x7f) + 1;
                        }

                        densities[idx].assign(old_densities.begin() + old_leaf_ptr, old_densities.begin() + old_leaf_ptr + leaves_in_chunk);
                        old_leaf_ptr += leaves_in_chunk;

                        for (int c = 0; c < 4; ++c) {
                            materials[c][idx].assign(old_mats.parts[c].begin() + old_mat_ptr, old_mats.parts[c].begin() + old_mat_ptr + leaves_in_chunk);
                        }
                        old_mat_ptr += leaves_in_chunk;
                        old_chunk_idx++;
                    } else {
                        signs[idx / 8] |= (1 << (idx % 8));
                        GeneratedChunk gen;
                        float ox = -size / 2.0f + x * 512.0f;
                        float oy = -512.0f + y * 512.0f;
                        float oz = -size / 2.0f + z * 512.0f;
                        build_octree_node(0, ox, oy, oz, 512.0f, mips[z * width + x], stock, gen);
                        chunks[idx] = std::move(gen.tree);
                        densities[idx] = std::move(gen.density);
                        for (int c = 0; c < 4; ++c) materials[c][idx] = std::move(gen.mat[c]);
                    }

                    done_chunks++;
                    if (done_chunks % 64 == 0) {
                        int pct = 10 + (done_chunks * 60) / total;
                        progress(pct, "Generating terrain octree");
                    }
                }
            }
        }

        progress(70, "Assembling volume buffers");
        std::vector<uint8_t> all_tree, all_density, all_mat;
        for (int i = 0; i < total; ++i) {
            all_tree.insert(all_tree.end(), chunks[i].begin(), chunks[i].end());
            all_density.insert(all_density.end(), densities[i].begin(), densities[i].end());
        }
        for (int c = 0; c < 4; ++c) {
            for (int i = 0; i < total; ++i) {
                all_mat.insert(all_mat.end(), materials[c][i].begin(), materials[c][i].end());
            }
        }

        std::vector<uint8_t> replacement;
        const uint8_t header_bytes[] = {0x05, 0x02, 0x01, 0x02, 0xc2, 0x00, 0x01, 0x00};
        replacement.insert(replacement.end(), std::begin(header_bytes), std::end(header_bytes));
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
