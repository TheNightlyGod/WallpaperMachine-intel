#pragma once
#include "Runtime/SceneModelData.hpp"
#include <quickjs.h>

namespace wallpaper {

// Owns temporary JS references only for the duration of a native call. Vertex
// and index payloads remain borrowed views, including their byte offsets.
class ModelDataInput {
public:
    explicit ModelDataInput(JSContext* context):ctx(context) {}
    ~ModelDataInput();
    ModelDataInput(const ModelDataInput&)=delete;
    ModelDataInput& operator=(const ModelDataInput&)=delete;
    bool Read(JSValueConst value,bool creating,const std::function<bool()>& continuing);
    ModelDataUpdate update;
    std::string error;
private:
    struct Buffer {
        std::size_t shape;
        bool index;
        JSValue backing;
        std::size_t offset,length;
        ModelDataBufferType type;
    };
    JSValue Keep(JSValue value);
    JSValue Get(JSValueConst object,const char* name);
    bool Shape(JSValueConst value,bool creating);
    bool Capture(JSValueConst value,std::size_t shape,bool index);
    bool Vector(JSValueConst value,linalg::Vector3f& result);
    JSContext* ctx;
    std::vector<JSValue> held;
    std::vector<Buffer> buffers;
};
} // namespace wallpaper
