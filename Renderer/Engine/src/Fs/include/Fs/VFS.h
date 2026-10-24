// Clean-room implementation from the WallpaperMachine spec e7-small-units.md; written without access to the original source.
#pragma once
#include <iterator>
#include <string_view>
#include <vector>
#include <memory>
#include <string>
#include <tuple>
#include <algorithm>
#include "Fs.h"
#include "Utils/Logging.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace  fs
{

class VFS : NoCopy,NoMove {
public:
	struct MountedFs {
		std::string name;
		std::string mountPoint;
		std::unique_ptr<Fs> fs;
		static bool CheckMountPoint(const std::string_view mountPoint) {
			return ! mountPoint.empty() && mountPoint.front() == '/' && mountPoint.back() != '/';
		}
		static bool InMountPoint(const std::string_view mountPoint, const std::string_view path) {
			// Covered means: the mount point, then a '/'. Bytes only, no normalising.
			return path.size() > mountPoint.size() && path.substr(0, mountPoint.size()) == mountPoint &&
			       path[mountPoint.size()] == '/';
		}
		static std::string GetPathInMount(const std::string_view mountPoint, const std::string_view path) {
			// What follows the mount point, still starting with '/'; empty if not covered.
			if (! InMountPoint(mountPoint, path)) return {};
			return std::string(path.substr(mountPoint.size()));
		}
	};
public:
	VFS() = default;
	~VFS() = default;

	bool Mount(std::string_view mountpoint, std::unique_ptr<Fs> fs, std::string_view name="") {
		if (! MountedFs::CheckMountPoint(mountpoint)) {
			LOG_ERROR("\"%.*s\" is not a valid mount point", (int)mountpoint.size(), mountpoint.data());
			return false;
		}
		if (! fs) {
			LOG_ERROR("can't mount a null file system at \"%.*s\"", (int)mountpoint.size(), mountpoint.data());
			return false;
		}
		// The last mount is the topmost one.
		m_mountedFss.push_back(MountedFs { std::string(name), std::string(mountpoint), std::move(fs) });
		return true;
	}
	bool Unmount(std::string_view mountpoint) {
		// Topmost first: search the mounts from the back.
		const auto top = std::find_if(m_mountedFss.rbegin(), m_mountedFss.rend(), [&](const MountedFs& m) {
			return m.mountPoint == mountpoint;
		});
		const bool found = top != m_mountedFss.rend();
		if (found) {
			m_mountedFss.erase(m_mountedFss.begin() + (std::distance(top, m_mountedFss.rend()) - 1));
		} else {
			LOG_INFO("nothing is mounted at \"%.*s\"", (int)mountpoint.size(), mountpoint.data());
		}
		return found;
	}
	bool IsMounted(std::string_view name) {
		if (name.empty()) return false;
		return std::any_of(m_mountedFss.begin(), m_mountedFss.end(), [name](const MountedFs& m) {
			return m.name == name;
		});
	}
	std::shared_ptr<IBinaryStream> Open(std::string_view path) {
		const MountedFs* owner = nullptr;
		std::string      inside;
		if (! Locate(path, &owner, &inside)) {
			LOG_ERROR("not found \"%.*s\" in any mounted file system", (int)path.size(), path.data());
			return nullptr;
		}
		return owner->fs->Open(inside);
	}
	std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) {
		// An existing file is overwritten where it lives; a new one goes to the top
		// of the mounts that cover its path.
		const MountedFs* owner = nullptr;
		std::string      inside;
		if (! Locate(path, &owner, &inside)) {
			for (auto it = m_mountedFss.rbegin(); it != m_mountedFss.rend(); ++it) {
				if (! MountedFs::InMountPoint(it->mountPoint, path)) continue;
				owner  = &*it;
				inside = MountedFs::GetPathInMount(it->mountPoint, path);
				break;
			}
		}
		if (owner == nullptr) {
			LOG_ERROR("no mounted file system covers \"%.*s\" for writing", (int)path.size(), path.data());
			return nullptr;
		}
		return owner->fs->OpenW(inside);
	}
	/// Publishes `from` as `to`, both of which must resolve to the same mount.
	///
	/// Refuses rather than approximating when they do not: moving a file across
	/// two file systems is a copy, and a copy is exactly what the callers of
	/// this are avoiding.
	bool Rename(std::string_view from, std::string_view to) {
		auto owner = std::find_if(m_mountedFss.rbegin(), m_mountedFss.rend(), [&to](const auto& mfs) {
			return MountedFs::InMountPoint(mfs.mountPoint, to);
		});
		if (owner == std::rend(m_mountedFss)) return false;
		if (! MountedFs::InMountPoint(owner->mountPoint, from)) return false;
		return owner->fs->Rename(MountedFs::GetPathInMount(owner->mountPoint, from),
		                         MountedFs::GetPathInMount(owner->mountPoint, to));
	}
	bool Contains(std::string_view path) const {
		const MountedFs* owner = nullptr;
		std::string      inside;
		return Locate(path, &owner, &inside);
	}
	/// The host path of the file `path` names, when the mount that holds it is a folder of
	/// real files (see `Fs::PhysicalPath`). Nothing is opened or read.
	bool PhysicalPath(std::string_view path, std::string* out) const {
		const MountedFs* owner = nullptr;
		std::string      inside;
		return Locate(path, &owner, &inside) && owner->fs->PhysicalPath(inside, out);
	}
private:
	// The topmost mount that covers `path` and holds the file, with the path as
	// that mount's file system knows it.
	bool Locate(std::string_view path, const MountedFs** owner, std::string* inside) const {
		for (auto it = m_mountedFss.rbegin(); it != m_mountedFss.rend(); ++it) {
			if (! MountedFs::InMountPoint(it->mountPoint, path)) continue;
			std::string rel = MountedFs::GetPathInMount(it->mountPoint, path);
			if (! it->fs->Contains(rel)) continue;
			*owner  = &*it;
			*inside = std::move(rel);
			return true;
		}
		return false;
	}

	std::vector<MountedFs> m_mountedFss;
};

inline std::string GetFileContent(fs::VFS& vfs, std::string_view path) {
	auto stream = vfs.Open(path);
	if (! stream) return {};
	return stream->ReadAllStr();
}

}
}
