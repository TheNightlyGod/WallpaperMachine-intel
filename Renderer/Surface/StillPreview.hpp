// A still picture shown on a wallpaper surface that has nothing of its own to
// draw.
//
// When a scene cannot be drawn with the native renderer and has not drawn a
// frame yet, the surface would be an empty layer: black. This puts the
// project's own preview picture there instead, so the wallpaper is recognisably
// the one that was chosen while the failure is reported. A scene that did draw
// keeps its last frame (the layer holds it) and never needs this.
//
// It owns no renderer and no GPU resources: the picture is decoded once with
// ImageIO and shown as a plain Core Animation sublayer of the surface's layer,
// so it costs nothing per frame and nothing while the surface is idle.
#pragma once

#include <memory>
#include <utility>
#include <string>

namespace wallpaper::surface
{

/// The project's preview picture, as the path of an image file, or empty when it
/// has none. `project_path` is the `project.json` of the wallpaper (or the folder
/// that holds it). Reads the project's `preview` key and falls back to the
/// conventional preview file names; the result is always inside the project's
/// own folder.
[[nodiscard]] std::string FindPreviewImage(const std::string& project_path);

class StillPreview {
public:
    StillPreview();
    ~StillPreview();
    StillPreview(const StillPreview&)            = delete;
    StillPreview& operator=(const StillPreview&) = delete;

    /// Shows the picture of `image_path` over the whole of `layer` (a `CALayer*`,
    /// the surface's `CAMetalLayer`), scaled to fill it and cropped to its
    /// shape. Replaces a picture already shown, including one on a layer the
    /// display has since replaced. False with `error` set when the file cannot
    /// be decoded; nothing is shown then.
    [[nodiscard]] bool Show(void* layer, const std::string& image_path, std::string& error);

    /// Takes the picture away. Harmless when none is shown.
    void Hide();

    [[nodiscard]] bool shown() const;

    /// The size in pixels of the decoded picture, or 0 x 0 when none is shown.
    /// What a test reads back instead of the screen.
    [[nodiscard]] std::pair<unsigned, unsigned> pictureSize() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};

} // namespace wallpaper::surface
