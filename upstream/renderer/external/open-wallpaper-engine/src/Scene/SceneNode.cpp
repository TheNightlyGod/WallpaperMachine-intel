#include "SceneNode.h"

#include <Eigen/Geometry>

using namespace wallpaper;
using namespace Eigen;

Matrix4d SceneNode::LocalTransOf(const Vector3f& translate, const Vector3f& scale,
                                 const Vector3f& rotation) {
    Affine3d trans = Affine3d::Identity();
    trans.prescale(scale.cast<double>());

    trans.prerotate(AngleAxis<double>(rotation.x(), Vector3d::UnitX())); // x
    trans.prerotate(AngleAxis<double>(rotation.y(), Vector3d::UnitY())); // y
    trans.prerotate(AngleAxis<double>(rotation.z(), Vector3d::UnitZ())); // z

    trans.pretranslate(translate.cast<double>());
    return trans.matrix();
}

Matrix4d SceneNode::GetLocalTrans() const {
    const Matrix4d local = LocalTransOf(m_translate, m_scale, m_rotation);
    if (m_attachmentTransform) return *m_attachmentTransform * local;
    return local;
}

void SceneNode::UpdateTrans() {
    if (! m_dirty) return;
    m_dirty = false;

    if (m_parent) {
        m_parent->UpdateTrans();
    }
    // What this node's own place is built on, and what its children's is: the
    // same, except where the node is drawn by something other than its own
    // transform (a fullscreen layer), whose children are placed from the
    // transform the scene saved for it.
    const Matrix4d parent_frame = m_parent ? m_parent->ChildTrans() : Matrix4d::Identity();
    const bool     inherits     = m_parent && ! m_ignoreParentTransform;
    m_trans = ((inherits ? parent_frame : Matrix4d::Identity()) * GetLocalTrans()).eval();
    m_childTrans = m_childLocal ? Matrix4d(parent_frame * *m_childLocal) : m_trans;
}

void SceneNode::MarkTransDirty() {
    if (! m_dirty) {
        m_dirty = true;
        for (auto& child : m_children) {
            child->MarkTransDirty();
        }
    }
}
