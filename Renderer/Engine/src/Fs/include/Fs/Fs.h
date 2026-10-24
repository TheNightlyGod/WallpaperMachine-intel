#pragma once
#include <memory>

#include "IBinaryStream.h"
#include "Core/NoCopyMove.hpp"

namespace wallpaper
{
namespace fs
{

class Fs : NoCopy,NoMove {
public:
	virtual bool Contains(std::string_view path) const = 0;
	virtual std::shared_ptr<IBinaryStream> Open(std::string_view path) = 0;
	virtual std::shared_ptr<IBinaryStreamW> OpenW(std::string_view path) = 0;
	/// Publishes a file already written at `from` under the name `to`, in one
	/// step, replacing whatever was there.
	///
	/// A file system that cannot do this says so rather than approximating it,
	/// and the caller writes in place instead. Nothing depends on the
	/// atomicity for correctness -- a half-written cache entry is rejected when
	/// it is read -- but a reader that never sees one is cheaper than a reader
	/// that has to recover from one.
	virtual bool Rename(std::string_view from, std::string_view to) {
		(void)from;
		(void)to;
		return false;
	}
	/// Where the file `path` names lies on the host disk, when this file space is a
	/// folder of real files. A reader that can open a path itself (a video decoder)
	/// uses it to play the file in place instead of reading it through the mount. A
	/// file space that has no such path says so by answering false.
	virtual bool PhysicalPath(std::string_view path, std::string* out) const {
		(void)path;
		(void)out;
		return false;
	}
public:
	Fs() = default;
	virtual ~Fs() = default;
};

}
}
