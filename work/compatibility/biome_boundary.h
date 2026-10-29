#pragma once

// The metadata geome can disagree with the actual original sandbox contour.
// Match a unique stock contour before choosing any donor terrain or scenery.
struct BoundaryBiome {
    const char* biome;
    const char* donor;
    double seed[3];
    double bounds[4];
};
static const BoundaryBiome stockBoundaryBiomes[]={
    {"temperate","TemperateSandbox",{505.0637512,46.2103386,498.8643494},{-500.7930603,505.0637512,-503.9561157,503.9422302}},
    {"tropical","TropicalSandbox",{-497.2756653,6.5644922,484.7773743},{-499.1105652,509.4645386,-504.4102783,499.5578918}},
    {"taiga","TaigaSandbox",{-486.1791382,76.1536713,-486.6044006},{-502.7882690,510.9080811,-511.0911560,413.6222229}},
    {"mediterranean","MediterraneanSandbox",{-506.6679993,10.1644068,-502.8905640},{-510.1216431,488.7711792,-507.6991882,510.1072693}}
};

static double readBoundaryNumber(const uint8_t* data,size_t length,size_t& pos) {
    if(pos>=length) throw std::runtime_error("Truncated boundary record");
    const uint8_t tag=data[pos++];
    if(tag<0x40) return tag;
    if(tag<0x80) return -double(tag&0x3f);
    if(tag<0xc0) {
        if(length-pos<3) throw std::runtime_error("Truncated boundary float");
        uint32_t bits=uint32_t(((tag&0x1f)+0x30)|((tag&0x20)<<2))<<24;
        for(int shift=16;shift>=0;shift-=8) bits|=uint32_t(data[pos++])<<shift;
        float value;std::memcpy(&value,&bits,4);
        if(!std::isfinite(value)) throw std::runtime_error("Nonfinite boundary coordinate");
        return value;
    }
    if(tag<=0xf0) {
        const int bytes=tag==0xf0?4:(tag>>4)-11;
        if(length-pos<size_t(bytes)) throw std::runtime_error("Truncated boundary integer");
        uint64_t value=tag==0xf0?0:tag&7;
        for(int i=0;i<bytes;++i)value=(value<<8)|data[pos++];
        return tag!=0xf0 && (tag&8)?-double(value):double(value);
    }
    throw std::runtime_error("Unsupported boundary number encoding");
}

static uint32_t parkBoundaryTypeIndex(const std::vector<uint8_t>& body) {
    const char marker[]="Strings>";
    const auto begin=std::search(body.begin(),body.end(),marker,marker+8);
    if(begin==body.end())throw std::runtime_error("Source string table is missing");
    size_t pos=size_t(begin-body.begin())+8;
    const double count=readBoundaryNumber(body.data(),body.size(),pos);
    if(count<1 || count>1000000 || std::floor(count)!=count)throw std::runtime_error("Invalid source string table");
    for(uint32_t i=0;i<uint32_t(count);++i) {
        if(pos>=body.size() || body[pos++]!=0xf3)throw std::runtime_error("Unsupported source string table entry");
        const auto end=std::find(body.begin()+pos,body.end(),uint8_t(0));
        if(end==body.end())throw std::runtime_error("Truncated source string table");
        const size_t length=size_t(end-(body.begin()+pos));
        if(length==12 && std::memcmp(body.data()+pos,"ParkBoundary",12)==0)return i;
        pos=size_t(end-body.begin())+1;
    }
    throw std::runtime_error("Source ParkBoundary type is missing");
}

static BoundaryBiome detectBoundaryBiome(const uint8_t* data,size_t length,uint32_t parkType) {
    size_t pos=0;
    const double version=readBoundaryNumber(data,length,pos);
    const double reserved=readBoundaryNumber(data,length,pos);
    const double countValue=readBoundaryNumber(data,length,pos);
    if(version!=4 || reserved!=0 || countValue<4 || countValue>100000 || std::floor(countValue)!=countValue)
        throw std::runtime_error("Unsupported source boundary layout; original park unchanged");
    double bounds[4]={1e9,-1e9,1e9,-1e9},seed[3]{};
    size_t parks=0;
    for(size_t i=0;i<size_t(countValue);++i) {
        double fields[10];for(auto& value:fields)value=readBoundaryNumber(data,length,pos);
        if(fields[8]!=parkType)continue; // Resolved through this save's string table.
        if(!parks)for(int axis=0;axis<3;++axis)seed[axis]=fields[axis+1];
        ++parks;
        bounds[0]=std::min(bounds[0],fields[1]);bounds[1]=std::max(bounds[1],fields[1]);
        bounds[2]=std::min(bounds[2],fields[3]);bounds[3]=std::max(bounds[3],fields[3]);
    }
    if(parks<4)throw std::runtime_error("Source park boundary is missing; original park unchanged");
    int match=-1;
    for(int i=0;i<4;++i) {
        bool same=true;for(int axis=0;axis<4;++axis)if(std::abs(bounds[axis]-stockBoundaryBiomes[i].bounds[axis])>=0.2)same=false;
        if(same) {
            if(match!=-1)throw std::runtime_error("Ambiguous source biome boundary; original park unchanged");
            match=i;
        }
    }
    if(match<0)throw std::runtime_error("Source contour does not match a supported original sandbox; original park unchanged");
    auto result=stockBoundaryBiomes[match];
    std::copy(seed,seed+3,result.seed);std::copy(bounds,bounds+4,result.bounds);
    return result;
}
