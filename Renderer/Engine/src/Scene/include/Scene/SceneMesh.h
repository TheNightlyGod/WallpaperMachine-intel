// Clean-room implementation from the WallpaperMachine spec e1b-scene-model.md; written without access to the original source.
#pragma once
#include <vector>
#include <memory>
#include <cstddef>
#include <cstdint>
#include <climits>
#include <atomic>
#include <span>
#include <string>
#include <utility>

#include "SceneVertexArray.h"
#include "SceneIndexArray.h"
#include "SceneMaterial.h"

namespace wallpaper
{

/// What rewrites a mesh's vertices, which is not the same question as whether
/// they can be rewritten at all.
///
/// `Dynamic()` -- the old single bit -- answers "may this geometry change after
/// parsing", which every consumer of a vertex buffer needs. It does not answer
/// "does this geometry change on its own", and the two were the same value for
/// as long as a particle system was the only thing that rewrote a mesh. A text
/// card is rewritten too, but only when something re-lays the text out, so a
/// scene holding one is not a scene that has to keep drawing.
enum class MeshUpdate : uint8_t {
	/// Written once while parsing and never again.
	Fixed = 0,
	/// Rewritten every frame by something that advances on its own -- a
	/// particle system. A scene holding one always has work to do.
	PerFrame = 1,
	/// Rewritten only when an event re-lays it out, and unchanged in between.
	/// Still uploaded through the dynamic path, still never reusable by the
	/// pixel cache; simply not a reason for the clock to keep running.
	OnEvent = 2,
};

class SceneMesh {
public:
	struct DrawRange {
		uint32_t indexOffset {0};
		uint32_t indexCount {0};
	};

	class Submesh {
	public:
		/// How many vertex arrays and index arrays it holds, not how many vertices.
		std::size_t VertexCount() const { return m_vertices.size(); }
		std::size_t IndexCount() const { return m_indices.size(); }

		const SceneVertexArray& GetVertexArray(const std::size_t index) const {
			return m_vertices.at(index);
		}
		const SceneIndexArray& GetIndexArray(const std::size_t index) const {
			return m_indices.at(index);
		}

		SceneVertexArray& GetVertexArray(const std::size_t index) { return m_vertices.at(index); }
		SceneIndexArray& GetIndexArray(const std::size_t index) { return m_indices.at(index); }

		void AddIndexArray(SceneIndexArray&& array) { m_indices.push_back(std::move(array)); }
		void AddVertexArray(SceneVertexArray&& array) { m_vertices.push_back(std::move(array)); }

		const std::vector<DrawRange>& DrawRanges() const { return m_ranges; }
		std::vector<DrawRange>& DrawRanges() { return m_ranges; }
		void SetDrawRanges(std::span<const DrawRange> ranges) {
			m_ranges.assign(ranges.begin(), ranges.end());
		}

		uint32_t material_slot {0};
		std::string output_override;

	private:
		std::vector<SceneVertexArray> m_vertices;
		std::vector<SceneIndexArray> m_indices;
		std::vector<DrawRange> m_ranges;
	};

	explicit SceneMesh(MeshUpdate update = MeshUpdate::Fixed)
		: m_update(update), m_geometry(std::make_shared<std::vector<Submesh>>()) {}

	std::size_t VertexCount() const { return m_geometry->empty() ? 0 : m_geometry->front().VertexCount(); }
	std::size_t IndexCount() const { return m_geometry->empty() ? 0 : m_geometry->front().IndexCount(); }

	MeshPrimitive Primitive() const { return m_primitive; }
	uint32_t PointSize() const { return m_pointSize; }

	/// Whether the vertices may be rewritten after parsing. Every upload,
	/// buffer-allocation and pixel-reuse decision asks this and nothing else.
	bool Dynamic() const { return m_update != MeshUpdate::Fixed; }
	/// What rewrites them. Ask this only when the answer changes whether the
	/// scene has to keep drawing; never to decide how to upload.
	MeshUpdate UpdateDriver() const { return m_update; }
	bool UpdatesOnEvent() const { return m_update == MeshUpdate::OnEvent; }
	const auto& Dirty() const { return m_dirty; }
	auto& Dirty() { return m_dirty; }
	/// Marks the geometry changed: the flag is raised and the generation moves on.
	void SetDirty() {
		m_generation.fetch_add(1, std::memory_order_acq_rel);
		m_dirty.store(true, std::memory_order_release);
	}
	uint64_t DirtyGeneration() const { return m_generation.load(std::memory_order_acquire); }

	uint32_t ID() const { return m_id; }
	void SetID(uint32_t v) { m_id = v; }

	// The geometry calls below speak for submesh 0. The writing forms start one when
	// there is none; the reading forms of a mesh without one are caller errors.
	const SceneVertexArray& GetVertexArray(const std::size_t index) const {
		return m_geometry->at(0).GetVertexArray(index);
	}
	const SceneIndexArray& GetIndexArray(const std::size_t index) const {
		return m_geometry->at(0).GetIndexArray(index);
	}

	SceneVertexArray& GetVertexArray(const std::size_t index) { return First().GetVertexArray(index); }
	SceneIndexArray& GetIndexArray(const std::size_t index) { return First().GetIndexArray(index); }

	void AddIndexArray(SceneIndexArray&& array) { First().AddIndexArray(std::move(array)); }
	void AddVertexArray(SceneVertexArray&& array) { First().AddVertexArray(std::move(array)); }
	void AddMaterial(SceneMaterial&& material) {
		m_materials.push_back(std::make_shared<SceneMaterial>(std::move(material)));
	}

	void SetPrimitive(MeshPrimitive v) { m_primitive = v; }
	void SetPointSize(uint32_t v) { m_pointSize = v; }

	SceneMaterial* Material() { return MaterialForSlot(0); }
	const SceneMaterial* Material() const { return MaterialForSlot(0); }
	SceneMaterial* MaterialForSlot(uint32_t slot) {
		return slot < m_materials.size() ? m_materials[slot].get() : nullptr;
	}
	const SceneMaterial* MaterialForSlot(uint32_t slot) const {
		return slot < m_materials.size() ? m_materials[slot].get() : nullptr;
	}

	const std::vector<Submesh>& Submeshes() const { return *m_geometry; }
	std::vector<Submesh>& Submeshes() { return *m_geometry; }

	const std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() const { return m_materials; }
	std::vector<std::shared_ptr<SceneMaterial>>& MaterialSlots() { return m_materials; }
	std::shared_ptr<SceneMaterial> MaterialSlotPtr(std::size_t index = 0) const {
		return index < m_materials.size() ? m_materials[index] : nullptr;
	}

	const std::vector<DrawRange>& DrawRanges() const {
		static const std::vector<DrawRange> none;
		return m_geometry->empty() ? none : m_geometry->front().DrawRanges();
	}
	std::vector<DrawRange>& DrawRanges() { return First().DrawRanges(); }
	void SetDrawRanges(std::span<const DrawRange> ranges) { First().SetDrawRanges(ranges); }

	/// Both meshes then read and write one store of submeshes; everything else a
	/// mesh holds (materials, primitive, point size, id, driver, dirty state) stays its own.
	void ChangeMeshDataFrom(const SceneMesh& o) { m_geometry = o.m_geometry; }

private:
	Submesh& First() {
		if (m_geometry->empty()) m_geometry->emplace_back();
		return m_geometry->front();
	}

	MeshUpdate m_update;
	MeshPrimitive m_primitive {MeshPrimitive::TRIANGLE};
	uint32_t m_pointSize {1};
	uint32_t m_id {0xFFFFFFFFu};
	std::shared_ptr<std::vector<Submesh>> m_geometry;
	std::vector<std::shared_ptr<SceneMaterial>> m_materials;
	std::atomic<bool> m_dirty {false};
	std::atomic<uint64_t> m_generation {0};
};

}
