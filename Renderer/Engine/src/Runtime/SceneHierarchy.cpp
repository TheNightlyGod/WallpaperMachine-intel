#include "SceneRuntimeContext.hpp"
#include "Scene/Scene.h"
#include "Scene/SceneNode.h"
#include "Scene/WPShaderValueUpdater.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace wallpaper {

void SceneRuntimeContext::RefreshPuppetAttachments(const WPPuppetLayer& layer) {
    if (!m_scene) return;
    if (auto* updater=dynamic_cast<WPShaderValueUpdater*>(m_scene->shaderValueUpdater.get()))
        updater->RefreshPuppetAttachments(layer);
}

int32_t SceneRuntimeContext::NodeAttachmentIndex(std::string_view name,
                                                std::string_view attachment) {
    const auto* puppet=FindPuppetLayer(name);
    return puppet ? puppet->attachmentIndex(attachment) : -1;
}

linalg::Matrix4d SceneRuntimeContext::NodeAttachmentMatrix(std::string_view name,
                                                         int32_t attachment) {
    const auto world=NodeTransformMatrix(name);
    auto* puppet=FindPuppetLayer(name);
    if (!puppet) return world;
    if (puppet->simulates()) puppet->setLayerWorld(world);
    puppet->genFrame(m_scene ? m_scene->elapsingTime : 0);
    const auto local=puppet->attachmentTransform(attachment);
    return local ? linalg::Matrix4d(world*local->matrix().cast<double>()) : world;
}

std::optional<linalg::Matrix3d> SceneRuntimeContext::AttachmentToTexture(
        std::string_view receiver, std::string_view target, int32_t attachment) {
    if (!m_scene || !m_scene->activeCamera) return std::nullopt;
    const auto from=m_nodes.find(target),to=m_nodes.find(receiver);
    if (from==m_nodes.end() || to==m_nodes.end() || !from->second || !to->second) return std::nullopt;
    const auto size=NodeSize(receiver);
    if (!(size.x()>0) || !(size.y()>0)) return std::nullopt;
    const auto camera_for=[&](std::string_view key, SceneNode* node) -> const SceneCamera* {
        auto* camera=m_scene->activeCamera;
        if (camera->IsPerspective()) return camera;
        const auto flags=m_image_layer_flags.find(key);
        if (flags!=m_image_layer_flags.end()) {
            if (!flags->second.flags.perspective) return camera;
            const auto lens=m_scene->cameras.find("global_perspective");
            return lens!=m_scene->cameras.end() && lens->second ? lens->second.get() : camera;
        }
        const auto own=m_scene->cameras.find(node->Camera());
        return own!=m_scene->cameras.end() && own->second && !own->second->IsLayerLocal()
            ? own->second.get() : camera;
    };
    const auto* source_camera=camera_for(target,from->second);
    const auto* receiver_camera=camera_for(receiver,to->second);
    const auto* updater=dynamic_cast<WPShaderValueUpdater*>(m_scene->shaderValueUpdater.get());
    const auto model_for=[&](SceneNode* node,const SceneCamera& camera) {
        if (updater) return updater->ModelForProjection(node,camera);
        node->UpdateTrans();return node->ModelTrans();
    };
    auto world=NodeAttachmentMatrix(target,attachment);
    const auto source_model=model_for(from->second,*source_camera);
    world.block<3,1>(0,3)+=linalg::Vector3d(source_model.block<3,1>(0,3)-from->second->ModelTrans().block<3,1>(0,3));
    const linalg::Matrix4d source_clip=source_camera->GetViewProjectionMatrix()*world;
    const auto receiver_model=model_for(to->second,*receiver_camera);
    const linalg::Matrix4d receiver_clip=receiver_camera->GetViewProjectionMatrix()*receiver_model;
    // The native ray/triangle helper writes a zero intersection on a parallel
    // or non-finite ray. The public query still returns a Mat3, with the usual
    // half-texel origin and a collapsed direction when both samples miss.
    const linalg::Vector2d no_intersection(0.5-0.5/size.x(),0.5+0.5/size.y());
    const auto collapsed=[&]() {
        linalg::Matrix3d matrix=linalg::Matrix3d::Zero();
        matrix(0,2)=no_intersection.x();matrix(1,2)=no_intersection.y();matrix(2,2)=1;
        return matrix;
    };
    linalg::FullPivLU<linalg::Matrix4d> lu(receiver_clip);
    if (!lu.isInvertible()) return collapsed();
    const auto local_from_clip=lu.inverse();
    const auto project=[&](double x) -> linalg::Vector2d {
        const linalg::Vector4d clip=source_clip*linalg::Vector4d(x,0,0,1);
        if (!clip.allFinite() || std::abs(clip.w())<1e-12) return no_intersection;
        const double nx=clip.x()/clip.w(),ny=clip.y()/clip.w();
        const linalg::Vector4d near_h=local_from_clip*linalg::Vector4d(nx,ny,0,1);
        const linalg::Vector4d far_h=local_from_clip*linalg::Vector4d(nx,ny,1,1);
        if (std::abs(near_h.w())<1e-12 || std::abs(far_h.w())<1e-12) return no_intersection;
        const linalg::Vector3d near=near_h.head<3>()/near_h.w();
        const linalg::Vector3d delta=far_h.head<3>()/far_h.w()-near;
        if (!near.allFinite() || !delta.allFinite()) return no_intersection;
        // Native rays are normalized in world space before the receiver's
        // inverse transform. Use the same float-epsilon determinant boundary,
        // independent of the camera's near/far distance and receiver scaling.
        const double world_length=(receiver_model.block<3,3>(0,0)*delta).norm();
        if (!(world_length>0) || !std::isfinite(world_length) ||
            !(std::abs(delta.z())>std::numeric_limits<float>::epsilon()*world_length))
            return no_intersection;
        const linalg::Vector3d point=near-delta*(near.z()/delta.z());
        // 0x1401E5DD0 uses the half-texel origin; texture coordinates point downwards.
        return linalg::Vector2d(0.5+(point.x()-0.5)/size.x(),0.5-(point.y()-0.5)/size.y());
    };
    const auto origin=project(0),axis=project(100);
    linalg::Vector2d direction=axis-origin;
    const auto length=direction.norm();
    direction=length>std::numeric_limits<float>::epsilon()
        ? linalg::Vector2d(direction/length) : linalg::Vector2d::Zero();
    linalg::Matrix3d result=linalg::Matrix3d::Identity();
    result(0,0)=direction.x();result(1,0)=direction.y();
    result(0,1)=direction.y();result(1,1)=-direction.x();
    result(0,2)=origin.x();result(1,2)=origin.y();
    return result;
}

bool SceneRuntimeContext::SetNodeParent(std::string_view name, std::string_view parent_name,
                                      int32_t attachment, bool adjust_transforms) {
    const auto found=m_nodes.find(name);
    if (found==m_nodes.end() || !found->second || !m_scene || !m_scene->sceneGraph) return false;
    auto* node=found->second;
    auto* new_parent=m_scene->sceneGraph.get();
    std::string_view parent_key;
    if (!parent_name.empty()) {
        const auto parent=m_nodes.find(ResolveLayerName(parent_name));
        if (parent!=m_nodes.end() && parent->second) {
            new_parent=parent->second;
            parent_key=parent->first;
        } else return false;
    }
    // Validate before unlinking: rejection must preserve the complete existing tree.
    for (auto* parent=new_parent;parent;parent=parent->Parent())
        if (parent==node) return false;
    auto* old_parent=node->Parent();
    if (!old_parent) return false;

    auto* updater=dynamic_cast<WPShaderValueUpdater*>(m_scene->shaderValueUpdater.get());
    auto* puppet=FindPuppetLayer(parent_key);
    auto binding=puppet ? puppet->attachmentBinding(attachment) : std::nullopt;
    if (!binding) attachment=-1;
    if (binding && !updater) return false;
    if (old_parent==new_parent &&
        ((attachment>=0 && node->AttachmentIndex()==attachment) ||
         (attachment<0 && !node->HasAttachmentTransform()))) return true;

    // The native limit counts composition boundaries, not ordinary parents or
    // the sum of sibling branches (0x1401DE750 / 0x1401DDB50). Inspect only on
    // this hierarchy edit; no additional per-frame state or walk is needed.
    const auto composition=[&](SceneNode* current) {
        return current->ParentingPassthrough();
    };
    int parent_depth=0;
    for(auto* parent=new_parent;parent;parent=parent->Parent())
        parent_depth+=composition(parent);
    const auto subtree_depth=[&](const auto& self, SceneNode* current) -> int {
        int children=0;
        for(const auto& child:current->GetChildren())
            children=std::max(children,self(self,child.get()));
        return int(composition(current))+children;
    };
    const bool composition_rejected=parent_depth+subtree_depth(subtree_depth,node)>3;
    if(composition_rejected) {
        // Unlike an ancestor cycle, this native refusal removes the previous
        // parent and attachment before reporting the error. Local components
        // remain unchanged even when adjustment was requested.
        new_parent=m_scene->sceneGraph.get();
        binding.reset();
        attachment=-1;
        adjust_transforms=false;
    }

    linalg::Vector3f translation,scale,rotation;
    if (adjust_transforms && binding) {
        // WE snaps an adjusted attachment to its own origin while retaining local scale.
        translation=linalg::Vector3f::Zero();rotation=linalg::Vector3f::Zero();scale=node->Scale();
    } else if (adjust_transforms) {
        const auto origin_of=[&](SceneNode* current) {
            if (current==node) return NodeTranslate(name);
            if (current==new_parent && !parent_key.empty()) return NodeTranslate(parent_key);
            const auto entry=m_nodes.find(current->Name());
            if (entry!=m_nodes.end() && entry->second==current) return NodeTranslate(entry->first);
            return linalg::Vector3f(current->Translate());
        };
        // Native parent adjustment uses the object's raw origin, before image alignment,
        // and composes rotation independently of scale (0x1401850A0 / 0x1401DD7D0).
        const auto raw_world=[&](const auto& self, SceneNode* current, bool unscaled,
                                 bool for_children) -> linalg::Matrix4d {
            if (!current || current==m_scene->sceneGraph.get()) return linalg::Matrix4d::Identity();
            linalg::Matrix4d local;
            if (for_children && current->LocalChildFrame()) {
                local=*current->LocalChildFrame();
                if (unscaled) for (int axis=0;axis<3;++axis) {
                    const auto length=local.col(axis).head<3>().norm();
                    if (length>1e-12) local.col(axis).head<3>()/=length;
                }
            } else {
                local=SceneNode::LocalTransOf(origin_of(current),
                    unscaled ? linalg::Vector3f::Ones() : current->Scale(),current->Rotation());
                if (current->AttachmentTransform()) local=*current->AttachmentTransform()*local;
            }
            return current->Parent() && !current->IgnoresParentTransform()
                ? linalg::Matrix4d(self(self,current->Parent(),unscaled,true)*local) : local;
        };
        const auto old_world=raw_world(raw_world,node,false,false);
        const auto parent_frame=node->IgnoresParentTransform() ? linalg::Matrix4d::Identity()
            : raw_world(raw_world,new_parent,false,true);
        const auto parent_rotation=node->IgnoresParentTransform() ? linalg::Matrix4d::Identity()
            : raw_world(raw_world,new_parent,true,true);
        if (std::abs(parent_frame.determinant())<1e-12 || std::abs(parent_rotation.determinant())<1e-12)
            return false;
        const linalg::Matrix4d local=parent_frame.inverse()*old_world;
        const linalg::Matrix4d unscaled=parent_rotation.inverse()*raw_world(raw_world,node,true,false);
        if (!local.allFinite() || !unscaled.allFinite()) return false;
        const double z=std::atan2(unscaled(1,0),unscaled(0,0));
        const double y=std::atan2(-unscaled(2,0),std::hypot(unscaled(2,1),unscaled(2,2)));
        const double x=std::atan2(std::sin(z)*unscaled(0,2)-std::cos(z)*unscaled(1,2),
                                  std::cos(z)*unscaled(1,1)-std::sin(z)*unscaled(0,1));
        rotation={static_cast<float>(x),static_cast<float>(y),static_cast<float>(z)};
        translation=local.block<3,1>(0,3).cast<float>();
        auto old_unit=node->IgnoresParentTransform() ? linalg::Matrix4d::Identity()
            : raw_world(raw_world,old_parent,false,true);
        if (node->AttachmentTransform()) old_unit=old_unit**node->AttachmentTransform();
        old_unit=old_unit*SceneNode::LocalTransOf(linalg::Vector3f::Zero(),linalg::Vector3f::Ones(),node->Rotation());
        const linalg::Matrix4d new_unit=parent_frame*SceneNode::LocalTransOf(
            linalg::Vector3f::Zero(),linalg::Vector3f::Ones(),rotation);
        for (int axis=0;axis<3;++axis) {
            const double denominator=new_unit.col(axis).norm();
            const double divisor=denominator>std::numeric_limits<float>::epsilon() ? denominator : 1.0;
            scale[axis]=static_cast<float>(node->Scale()[axis]*old_unit.col(axis).norm()/divisor);
        }
    }

    if (old_parent!=new_parent) {
        auto& siblings=old_parent->GetChildren();
        const auto entry=std::find_if(siblings.begin(),siblings.end(),[node](const auto& child){return child.get()==node;});
        if (entry==siblings.end()) return false;
        auto owned=*entry;siblings.erase(entry);new_parent->AppendChild(std::move(owned));
    }
    if (updater) updater->ForgetPuppetAttachment(node);
    node->ClearAttachmentTransform();
    if (binding) updater->RegisterPuppetAttachments(*puppet,{{node,binding->bone_index,binding->bind_transform,attachment}});
    if (adjust_transforms) {
        SetNodeScale(name,scale);
        SetNodeRotation(name,rotation);
        SetNodeTranslate(name,translation);
    }
    if (old_parent!=new_parent) {
        MarkSceneGraphMutated("reparent");
        InvalidateVolumetricVisibility(node);
    }
    return !composition_rejected;
}
} // namespace wallpaper
