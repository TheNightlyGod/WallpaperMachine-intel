#include "Scripting/ModelDataInput.hpp"

#include <limits>

namespace wallpaper {
ModelDataInput::~ModelDataInput() {
    for (const auto value:held) JS_FreeValue(ctx,value);
}
JSValue ModelDataInput::Keep(JSValue value) {
    held.push_back(value);
    return value;
}
JSValue ModelDataInput::Get(JSValueConst object,const char* name) {
    return Keep(JS_GetPropertyStr(ctx,object,name));
}
bool ModelDataInput::Capture(JSValueConst value,std::size_t shape,bool index) {
    const int type=JS_GetTypedArrayType(value);
    const auto native=type==JS_TYPED_ARRAY_FLOAT32?ModelDataBufferType::Float32:
        type==JS_TYPED_ARRAY_UINT16?ModelDataBufferType::UInt16:ModelDataBufferType::UInt32;
    std::size_t offset=0,length=0,element=0;
    const auto backing=Keep(JS_GetTypedArrayBuffer(ctx,value,&offset,&length,&element));
    if (JS_IsException(backing)) return false;
    buffers.push_back({shape,index,backing,offset,length,native});
    return true;
}
bool ModelDataInput::Shape(JSValueConst value,bool creating) {
    const std::size_t at=update.shapes.size();
    update.shapes.emplace_back();
    auto& shape=update.shapes.back();
    if (JS_IsNull(value)) {shape.remove=true;return true;}
    if (!JS_IsObject(value)) return true;
    const auto vertices=Get(value,"vertexBuffer");
    if (JS_IsException(vertices)) return false;
    if (JS_GetTypedArrayType(vertices)==JS_TYPED_ARRAY_FLOAT32) {
        if (!Capture(vertices,at,false)) return false;
    } else if (creating) {error="Vertex buffer missing";return false;}
    const auto indices=Get(value,"indexBuffer");
    if (JS_IsException(indices)) return false;
    const int type=JS_GetTypedArrayType(indices);
    if (type==JS_TYPED_ARRAY_UINT16 || type==JS_TYPED_ARRAY_UINT32) {
        if (!Capture(indices,at,true)) return false;
    } else if (JS_IsNull(indices)) shape.remove_indices=true;
    const auto format=Get(value,"vertexFormat");
    if (JS_IsException(format)) return false;
    uint32_t flags=0;
    if (JS_IsArray(format)) {
        const auto length=Get(format,"length");
        uint32_t count=0;
        if (JS_ToUint32(ctx,&count,length)<0) return false;
        for (uint32_t i=0;i<count;++i) {
            const auto component=Keep(JS_GetPropertyUint32(ctx,format,i));
            if (JS_IsException(component)) return false;
            if (!JS_IsString(component)) break;
            const char* text=JS_ToCString(ctx,component);
            if (!text) return false;
            const std::string_view name(text);
            flags|=name=="position"?1u:name=="normal"?2u:name=="tangentSigned"?4u:
                name=="uv"?8u:name=="color"?0x8000u:0u;
            JS_FreeCString(ctx,text);
        }
    }
    if (flags) shape.format=flags;
    else if (creating) {error="Vertex format missing";return false;}
    const auto material=Get(value,"material");
    if (JS_IsException(material)) return false;
    if (JS_IsString(material)) {
        const char* text=JS_ToCString(ctx,material);
        if (!text) return false;
        shape.material=std::string(text);
        JS_FreeCString(ctx,text);
    } else if (creating) {error="Material missing";return false;}
    const auto dynamic_vertex=Get(value,"isVertexBufferDynamic");
    if (JS_IsException(dynamic_vertex)) return false;
    const auto dynamic_index=Get(value,"isIndexBufferDynamic");
    if (JS_IsException(dynamic_index)) return false;
    if (JS_IsBool(dynamic_vertex)) shape.dynamic_vertices=JS_ToBool(ctx,dynamic_vertex);
    if (JS_IsBool(dynamic_index)) shape.dynamic_indices=JS_ToBool(ctx,dynamic_index);
    return true;
}
bool ModelDataInput::Vector(JSValueConst value,linalg::Vector3f& result) {
    for (uint32_t i=0;i<3;++i) {
        const char* names[]={"x","y","z"};
        const auto lane=JS_IsArray(value)?Keep(JS_GetPropertyUint32(ctx,value,i)):Get(value,names[i]);
        double number=0;
        if (JS_IsException(lane) || JS_ToFloat64(ctx,&number,lane)<0) return false;
        result[i]=static_cast<float>(number);
    }
    return true;
}
bool ModelDataInput::Read(JSValueConst value,bool creating,const std::function<bool()>& continuing) {
    Keep(JS_DupValue(ctx,value));
    JSValue shapes=JS_UNDEFINED;
    if (JS_IsObject(value)) shapes=Get(value,"shapes");
    if (JS_IsException(shapes)) return false;
    if (JS_IsArray(shapes)) {
        uint32_t count=0;
        const auto length=Get(shapes,"length");
        if (JS_ToUint32(ctx,&count,length)<0) return false;
        for (uint32_t i=0;i<count;++i) {
            if (continuing && !continuing()) {error="Model data operation interrupted";return false;}
            const auto shape=Keep(JS_GetPropertyUint32(ctx,shapes,i));
            if (JS_IsException(shape) || !Shape(shape,creating)) return false;
        }
    } else if (!Shape(value,creating)) return false;
    if (JS_IsObject(value)) {
        const auto low=Get(value,"boundingBoxMins");
        const auto high=Get(value,"boundingBoxMaxs");
        if (JS_IsException(low) || JS_IsException(high)) return false;
        if (JS_IsObject(low) && JS_IsObject(high)) {
            linalg::Vector3f a,b;
            if (!Vector(low,a) || !Vector(high,b)) return false;
            update.bounds_min=a;update.bounds_max=b;
        }
    }
    // Property accessors above can execute JS and detach/resize a previously
    // read buffer. Resolve the borrowed bytes only after all accessors finished.
    for (const auto& buffer:buffers) {
        std::size_t size=0;
        const auto* data=JS_GetArrayBuffer(ctx,&size,buffer.backing);
        if (JS_HasException(ctx)) return false;
        if (buffer.offset>size || buffer.length>size-buffer.offset || (!data && buffer.length)) {
            error="Detached or resized model buffer";return false;
        }
        const auto* begin=data?data+buffer.offset:nullptr;
        ModelDataBufferView view {buffer.type,
            {reinterpret_cast<const std::byte*>(begin),buffer.length}};
        if (buffer.index) update.shapes[buffer.shape].indices=view;
        else update.shapes[buffer.shape].vertices=view;
    }
    return true;
}
} // namespace wallpaper
