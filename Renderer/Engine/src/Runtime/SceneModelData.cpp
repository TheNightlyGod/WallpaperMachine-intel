#include "Runtime/SceneModelData.hpp"
#include "Runtime/SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneCamera.h"
#include "Scene/SceneNode.h"
#include "Interface/IShaderValueUpdater.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>

namespace wallpaper {
namespace {
std::atomic<uint64_t> next_model_token {1};
constexpr uint32_t kPosition=1, kNormal=2, kTangent=4, kUv=8, kColor=0x8000;

std::vector<SceneVertexArray::SceneVertexAttribute> Attributes(uint32_t format) {
    std::vector<SceneVertexArray::SceneVertexAttribute> out;
    const auto add=[&](uint32_t bit,const char* name,VertexType type) {
        if (format&bit) out.push_back({name,type,false});
    };
    add(kPosition,"a_Position",VertexType::FLOAT3);
    add(kNormal,"a_Normal",VertexType::FLOAT3);
    add(kTangent,"a_Tangent4",VertexType::FLOAT4);
    add(kUv,"a_TexCoord",VertexType::FLOAT2);
    add(kColor,"a_Color",VertexType::FLOAT4);
    return out;
}
std::span<const std::byte> VertexBytes(const SceneMesh::Submesh& mesh) {
    const auto& v=mesh.GetVertexArray(0);
    return {reinterpret_cast<const std::byte*>(v.Data()),v.DataSizeOf()};
}
ModelDataBufferView IndexBytes(const SceneMesh::Submesh& mesh) {
    const auto& i=mesh.GetIndexArray(0);
    return {i.Width()==SceneIndexWidth::UInt16?ModelDataBufferType::UInt16:ModelDataBufferType::UInt32,
        {reinterpret_cast<const std::byte*>(i.Data()),i.DrawIndexBytes()}};
}
bool Fail(std::string& error,const char* reason) { error=reason;return false; }

// A replacement is prepared independently; no visible layer or old geometry is
// changed until every shape and material passed validation.
std::shared_ptr<ModelDataResource> Prepare(
    const ModelDataUpdate& update,const std::shared_ptr<ModelDataResource>& old,
    const ModelDataMaterialLoader& loader,std::string& error) {
    auto result=std::make_shared<ModelDataResource>();
    const auto count=std::max(update.shapes.size(),old?old->shapes.size():0u);
    result->shapes.resize(count);
    bool dynamic=false;
    std::vector<SceneMesh::Submesh> geometry;
    std::vector<std::shared_ptr<SceneMaterial>> materials;
    linalg::Vector3f low=linalg::Vector3f::Constant(std::numeric_limits<float>::infinity());
    linalg::Vector3f high=-low;
    bool have_position=false;
    for (std::size_t at=0;at<count;++at) {
        const ModelDataShapeUpdate empty;
        const auto& patch=at<update.shapes.size()?update.shapes[at]:empty;
        const auto* previous=old && at<old->shapes.size() && old->shapes[at]
            ? &*old->shapes[at]:nullptr;
        if (patch.remove) continue;
        if (!previous && !patch.vertices && !patch.format && !patch.material) continue;
        ModelDataShape shape=previous?*previous:ModelDataShape{};
        if (patch.format && *patch.format) shape.format=*patch.format;
        if (patch.material && !patch.material->empty()) shape.material_path=*patch.material;
        if (patch.dynamic_vertices) shape.dynamic_vertices=*patch.dynamic_vertices;
        if (patch.dynamic_indices) shape.dynamic_indices=*patch.dynamic_indices;
        if (!shape.format) {Fail(error,"Vertex format missing");return {};}
        if (shape.material_path.empty()) {Fail(error,"Material missing");return {};}
        const SceneMesh::Submesh* old_mesh=previous?&old->mesh->Submeshes()[previous->submesh]:nullptr;
        const auto vertices=patch.vertices?*patch.vertices:ModelDataBufferView{
            ModelDataBufferType::Float32,old_mesh?VertexBytes(*old_mesh):std::span<const std::byte>{}};
        if (!patch.vertices && !old_mesh) {Fail(error,"Vertex buffer missing");return {};}
        const auto attributes=Attributes(shape.format);
        std::size_t stride=0;
        for (const auto& attribute:attributes) stride+=SceneVertexArray::TypeCount(attribute.type);
        if (!stride || vertices.type!=ModelDataBufferType::Float32 ||
            vertices.bytes.size()%(stride*sizeof(float)) ||
            vertices.bytes.size()/sizeof(float)>std::numeric_limits<uint32_t>::max()) {
            Fail(error,"Inconsistent vertex buffer size");return {};
        }
        std::optional<ModelDataBufferView> indices;
        if (!patch.remove_indices) {
            if (patch.indices) indices=patch.indices;
            else if (old_mesh && old_mesh->IndexCount()) indices=IndexBytes(*old_mesh);
        }
        if (indices && (indices->type==ModelDataBufferType::Float32 ||
            indices->bytes.size()%(indices->type==ModelDataBufferType::UInt16?2u:4u))) {
            Fail(error,"Incorrect index buffer type");return {};
        }
        if (!previous || previous->material_path!=shape.material_path || previous->format!=shape.format) {
            shape.material=loader?loader(shape.material_path,shape.format,error):nullptr;
            if (!shape.material || !shape.material->material) {
                if (error.empty()) error="Invalid material";
                return {};
            }
        }
        if ((shape.material->required_format&shape.format)!=shape.material->required_format) {
            Fail(error,"Shader expecting more vertex data");return {};
        }
        SceneMesh::Submesh submesh;
        submesh.material_slot=static_cast<uint32_t>(materials.size());
        submesh.dynamic_vertices=shape.dynamic_vertices;
        submesh.dynamic_indices=shape.dynamic_indices;
        SceneVertexArray array(attributes,vertices.bytes.size()/(stride*sizeof(float)));
        // Typed-array views have aligned storage. The bridge retains their backing
        // buffers until this synchronous copy has finished.
        if (!vertices.bytes.empty())
            array.SetVertexs(0,{reinterpret_cast<const float*>(vertices.bytes.data()),vertices.bytes.size()/sizeof(float)});
        if (shape.format&kPosition) {
            const auto* data=array.Data();
            for (std::size_t i=0;i<array.VertexCount();++i) {
                const linalg::Vector3f point(data+i*stride);
                if (!point.allFinite()) continue;
                low=low.cwiseMin(point);high=high.cwiseMax(point);have_position=true;
            }
        }
        submesh.AddVertexArray(std::move(array));
        if (indices) {
            if (indices->type==ModelDataBufferType::UInt16) submesh.AddIndexArray(SceneIndexArray(
                std::span(reinterpret_cast<const uint16_t*>(indices->bytes.data()),indices->bytes.size()/2)));
            else submesh.AddIndexArray(SceneIndexArray::FromUInt32(
                std::span(reinterpret_cast<const uint32_t*>(indices->bytes.data()),indices->bytes.size()/4)));
        }
        shape.submesh=static_cast<uint32_t>(geometry.size());
        dynamic|=shape.dynamic_vertices||shape.dynamic_indices;
        geometry.push_back(std::move(submesh));
        materials.push_back(shape.material->material);
        result->shapes[at]=std::move(shape);
    }
    result->mesh=std::make_shared<SceneMesh>(dynamic?MeshUpdate::OnEvent:MeshUpdate::Fixed);
    result->mesh->EnableSharedGeometryUpdates();
    result->mesh->Submeshes()=std::move(geometry);
    result->mesh->MaterialSlots()=std::move(materials);
    result->mesh->SetDirty();
    if (update.bounds_min && update.bounds_max) {
        if (!update.bounds_min->allFinite() || !update.bounds_max->allFinite()) {
            Fail(error,"Invalid model bounds");return {};
        }
        result->bounds_min=*update.bounds_min;result->bounds_max=*update.bounds_max;
        result->explicit_bounds=true;
    } else if (old && old->explicit_bounds) {
        result->bounds_min=old->bounds_min;result->bounds_max=old->bounds_max;
        result->explicit_bounds=true;
    } else if (have_position) {
        result->bounds_min=low;result->bounds_max=high;
    }
    return result;
}
} // namespace

void SceneRuntimeContext::ConfigureModelData(ModelDataMaterialLoader loader,ModelDataLayerSetup setup) {
    if (!m_model_data) m_model_data=std::make_unique<SceneModelDataState>();
    m_model_data->load_material=std::move(loader);
    m_model_data->setup_layer=std::move(setup);
}

uint32_t SceneRuntimeContext::CreateModelData(const ModelDataUpdate& configuration,std::string& error) {
    if (!m_scene || !m_model_data || !m_model_data->load_material) {error="Model data is unavailable";return 0;}
    if (configuration.shapes.empty()) return 0;
    auto resource=Prepare(configuration,{},m_model_data->load_material,error);
    if (!resource) return 0;
    const uint64_t token=next_model_token.fetch_add(1,std::memory_order_relaxed);
    if (!token || token>std::numeric_limits<uint32_t>::max()) {error="Model data token space exhausted";return 0;}
    m_model_data->resources.emplace(static_cast<uint32_t>(token),std::move(resource));
    return static_cast<uint32_t>(token);
}

bool SceneRuntimeContext::UpdateModelData(
    uint32_t token,const ModelDataUpdate& update,bool replace,std::string& error) {
    if (!m_model_data) return Fail(error,"Invalid model data token");
    const auto found=m_model_data->resources.find(token);
    if (found==m_model_data->resources.end()) return Fail(error,"Invalid model data token");
    auto resource=found->second;
    if (replace) {
        auto next=Prepare(update,resource,m_model_data->load_material,error);
        if (!next) return false;
        next->layers=resource->layers;
        next->destroy_requested=resource->destroy_requested;
        found->second=next;
        for (const auto& layer:next->layers) InstallModelDataLayer(layer,next);
        if (!next->layers.empty()) MarkSceneGraphMutated("model-data-replace");
        return true;
    }
    if (update.bounds_min && update.bounds_max &&
        (!update.bounds_min->allFinite() || !update.bounds_max->allFinite()))
        return Fail(error,"Invalid model bounds");
    // Validate the whole patch before touching any stream. applyData never
    // changes the prepared layout or allocates replacement geometry.
    for (std::size_t at=0;at<update.shapes.size();++at) {
        const auto& patch=update.shapes[at];
        if (patch.remove || patch.remove_indices) return Fail(error,"Cannot delete shape or buffers in IModelData.update");
        if (at>=resource->shapes.size() || !resource->shapes[at])
            return Fail(error,"Cannot add shapes in IModelData.update");
        const auto& shape=*resource->shapes[at];
        const auto& mesh=resource->mesh->Submeshes()[shape.submesh];
        if (patch.format && *patch.format && *patch.format!=shape.format)
            return Fail(error,"Vertex format cannot be changed in IModelData.update");
        if (patch.material && !patch.material->empty() && *patch.material!=shape.material_path)
            return Fail(error,"Material cannot be changed in IModelData.update");
        if (patch.vertices) {
            if (!shape.dynamic_vertices) return Fail(error,"Model data not created as dynamic");
            if (patch.vertices->type!=ModelDataBufferType::Float32 ||
                patch.vertices->bytes.size()%mesh.GetVertexArray(0).OneSizeOf())
                return Fail(error,"Inconsistent vertex buffer size");
            if (patch.vertices->bytes.size()>mesh.GetVertexArray(0).CapacitySizeOf())
                return Fail(error,"Vertex buffer size cannot increase");
        }
        if (patch.indices) {
            if (!mesh.IndexCount()) return Fail(error,"Cannot add an index buffer in IModelData.update");
            const auto& indices=mesh.GetIndexArray(0);
            const auto expected=indices.Width()==SceneIndexWidth::UInt16
                ? ModelDataBufferType::UInt16:ModelDataBufferType::UInt32;
            if (patch.indices->type!=expected) return Fail(error,"Incorrect index buffer type");
            if (!shape.dynamic_indices) return Fail(error,"Model data not created as dynamic");
            if (patch.indices->bytes.size()>indices.CapacitySizeof())
                return Fail(error,"Index buffer size cannot increase");
        }
    }
    bool changed=false;
    for (std::size_t at=0;at<update.shapes.size();++at) {
        const auto& patch=update.shapes[at];
        auto& mesh=resource->mesh->Submeshes()[resource->shapes[at]->submesh];
        if (patch.vertices && !patch.vertices->bytes.empty()) {
            const auto bytes=patch.vertices->bytes;
            mesh.GetVertexArray(0).SetVertexs(0,{reinterpret_cast<const float*>(bytes.data()),bytes.size()/sizeof(float)});
            changed=true;
        }
        if (patch.indices && !patch.indices->bytes.empty()) {
            const auto bytes=patch.indices->bytes;
            if (patch.indices->type==ModelDataBufferType::UInt16)
                mesh.GetIndexArray(0).AssignHalf(0,{reinterpret_cast<const uint16_t*>(bytes.data()),bytes.size()/2});
            else mesh.GetIndexArray(0).Assign(0,{reinterpret_cast<const uint32_t*>(bytes.data()),bytes.size()/4});
            changed=true;
        }
    }
    if (changed) resource->mesh->SetDirty();
    if (update.bounds_min && update.bounds_max) {
        resource->bounds_min=*update.bounds_min;resource->bounds_max=*update.bounds_max;
        resource->explicit_bounds=true;
        for (const auto& layer:resource->layers)
            RegisterNodeSize(layer,(resource->bounds_max-resource->bounds_min).head<2>());
    }
    return true;
}

void SceneRuntimeContext::DestroyModelData(uint32_t token) {
    if (!m_model_data) return;
    const auto found=m_model_data->resources.find(token);
    if (found==m_model_data->resources.end()) return;
    if (found->second->layers.empty()) m_model_data->resources.erase(found);
    else found->second->destroy_requested=true;
}

std::string SceneRuntimeContext::CreateModelDataLayer(
    uint32_t token,const ModelDataLayerOptions& options,std::string_view creator) {
    if (!m_scene || !m_model_data) return {};
    const auto found=m_model_data->resources.find(token);
    if (found==m_model_data->resources.end()) return {};
    const auto resource=found->second;
    const auto key="__generated_model_"+std::to_string(m_next_generated_layer_key++);
    auto node=std::make_shared<SceneNode>();
    node->SetReflection(SceneNode::ReflectionKind::Model, options.reflected);
    node->SetName(key);node->ID()=m_next_generated_layer_id++;
    SceneNode* parent=m_scene->sceneGraph.get();
    if (const auto owner=m_nodes.find(std::string(creator));owner!=m_nodes.end() && owner->second->Parent())
        parent=owner->second->Parent();
    parent->AppendChild(node);
    RegisterNode(key,node.get());
    RegisterLayerId(node->ID(),key);
    m_script_created_layers.insert(key);
    m_model_data->layers.emplace(key,ModelDataLayer{token,node,linalg::Vector3f::Ones(),options});
    resource->layers.insert(key);
    InstallModelDataLayer(key,resource);
    MarkSceneGraphMutated("model-data-layer");
    return key;
}

void SceneRuntimeContext::InstallModelDataLayer(
    std::string_view name,const std::shared_ptr<ModelDataResource>& resource) {
    const auto held=m_model_data->layers.find(std::string(name));
    if (held==m_model_data->layers.end()) return;
    auto& layer=held->second;
    const auto node=layer.node.lock();
    if (!node) return;
    const auto parallax = m_scene->shaderValueUpdater
        ? m_scene->shaderValueUpdater->NodeParallaxDepth(node.get()) : std::array<float,2>{0,0};
    if (node->Mesh()) for (const auto& material:node->Mesh()->MaterialSlots())
        ForgetSceneUniformMaterial(material);
    if (m_scene->shaderValueUpdater) m_scene->shaderValueUpdater->ForgetNode(node.get());
    auto mesh=std::make_shared<SceneMesh>(resource->mesh->UpdateDriver());
    mesh->ShareGeometryFrom(*resource->mesh);
    std::vector<std::shared_ptr<ModelDataMaterial>> definitions;
    const float alpha=NodeAlpha(name).value_or(1);
    for (const auto& shape:resource->shapes) if (shape) {
        auto material=std::make_shared<SceneMaterial>(*shape->material->material);
        ApplyModelDataMaterialTint(*material,layer.color,alpha);
        mesh->MaterialSlots().push_back(material);
        definitions.push_back(shape->material);
        AddSceneUniformMaterial(material);
    }
    node->AddMesh(mesh);
    m_node_alpha[std::string(name)]={mesh->MaterialSlots(),alpha};
    RegisterNodeSize(std::string(name),(resource->bounds_max-resource->bounds_min).head<2>());
    node->SetCamera(layer.options.perspective ||
        (m_scene->activeCamera && m_scene->activeCamera->IsPerspective())?"global_perspective":"");
    SetNodeCursorTarget(name,true,layer.options.solid,layer.options.disablepropagation);
    RegisterModelFlags(std::string(name),false,layer.options.castshadow);
    node->SetCastsShadow(layer.options.castshadow);
    for (uint32_t slot=0;slot<definitions.size();++slot)
        if (definitions[slot]->attach) definitions[slot]->attach(node,slot);
    if (m_model_data->setup_layer) m_model_data->setup_layer(node,definitions,layer.options);
    if (m_scene->shaderValueUpdater)
        m_scene->shaderValueUpdater->SetNodeParallaxDepth(node.get(),parallax[0],parallax[1]);
    m_node_alpha[std::string(name)].materials = mesh->MaterialSlots();
}

void SceneRuntimeContext::ForgetModelDataLayer(std::string_view name) {
    if (!m_model_data) return;
    const auto layer=m_model_data->layers.find(std::string(name));
    if (layer==m_model_data->layers.end()) return;
    const auto resource=m_model_data->resources.find(layer->second.resource);
    if (resource!=m_model_data->resources.end()) {
        resource->second->layers.erase(std::string(name));
        if (resource->second->destroy_requested && resource->second->layers.empty())
            m_model_data->resources.erase(resource);
    }
    m_model_data->layers.erase(layer);
}

std::optional<linalg::Vector3f> SceneRuntimeContext::ModelDataLayerColor(std::string_view name) const {
    if (!m_model_data) return {};
    const auto layer=m_model_data->layers.find(std::string(name));
    return layer==m_model_data->layers.end()?std::nullopt:std::optional(layer->second.color);
}
bool SceneRuntimeContext::SetModelDataLayerColor(std::string_view name,const linalg::Vector3f& color) {
    if (!m_model_data) return false;
    const auto layer=m_model_data->layers.find(std::string(name));
    if (layer==m_model_data->layers.end()) return false;
    layer->second.color=color;
    if (const auto node=layer->second.node.lock();node && node->Mesh())
        for (const auto& material:node->Mesh()->MaterialSlots())
            if (material) ApplyModelDataMaterialTint(*material,color,NodeAlpha(name).value_or(1));
    return true;
}
std::optional<linalg::Vector2f> SceneRuntimeContext::ModelDataLayerBoxCentre(std::string_view name) const {
    if (!m_model_data) return {};
    const auto layer=m_model_data->layers.find(std::string(name));
    if (layer==m_model_data->layers.end()) return {};
    const auto resource=m_model_data->resources.find(layer->second.resource);
    if (resource==m_model_data->resources.end()) return {};
    return ((resource->second->bounds_min+resource->second->bounds_max)*0.5f).head<2>();
}
} // namespace wallpaper
