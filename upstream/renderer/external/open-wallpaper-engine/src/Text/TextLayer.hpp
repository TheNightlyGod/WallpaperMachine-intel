#pragma once

#include "Text/SystemFontResolver.hpp"

#include <Eigen/Dense>

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace wallpaper
{

class SharedFontData {
public:
    using const_iterator = std::vector<uint8_t>::const_iterator;

    SharedFontData() = default;
    SharedFontData(std::vector<uint8_t> data) {
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
    }
    SharedFontData(const SharedFontData&) noexcept            = default;
    SharedFontData(SharedFontData&&) noexcept                 = default;
    SharedFontData& operator=(const SharedFontData&) noexcept = default;
    SharedFontData& operator=(SharedFontData&&) noexcept      = default;

    SharedFontData& operator=(std::vector<uint8_t> data) {
        m_data.reset();
        if (! data.empty()) {
            m_data = std::make_shared<std::vector<uint8_t>>(std::move(data));
        }
        return *this;
    }

    bool empty() const { return storage().empty(); }
    std::size_t size() const { return storage().size(); }
    const uint8_t* data() const { return storage().data(); }
    const std::vector<uint8_t>& bytes() const { return storage(); }
    const_iterator begin() const { return storage().begin(); }
    const_iterator end() const { return storage().end(); }

private:
    const std::vector<uint8_t>& storage() const {
        static const std::vector<uint8_t> empty;
        return m_data == nullptr ? empty : *m_data;
    }

    std::shared_ptr<const std::vector<uint8_t>> m_data;
};

/// The look Wallpaper Engine gives text through its signed-distance-field font
/// shader: an outline around the glyphs, soft edges, and a drop shadow. The
/// fields are the scene file's, in the units it writes them in; they are pixels
/// of the rasterised text, as Wallpaper Engine scales them with the point size.
/// `msdf` alone only changes how that shader reconstructs the glyph edges, which
/// FreeType's own coverage already gives, so it has no field here.
struct TextStyle {
    bool            outline { false };
    float           outline_thickness { 4.0f };
    Eigen::Vector3f outline_color { Eigen::Vector3f::Zero() };
    bool            blur { false };
    float           blur_size { 6.0f };
    bool            drop_shadow { false };
    float           shadow_size { 6.0f };
    float           shadow_opacity { 1.0f };
    Eigen::Vector2f shadow_offset { 4.0f, 4.0f };
    Eigen::Vector3f shadow_color { Eigen::Vector3f::Zero() };
};

/// True when the text is drawn through the font shader's outline, blur or
/// shadow combos, which Wallpaper Engine turns on from the same fields.
bool TextStyleActive(const TextStyle& style);

/// Where a text layer's origin sits along each axis of its text. Wallpaper
/// Engine registers `horizontalalign` and `verticalalign` as enumerations whose
/// words match exactly (case counts) and, when nothing matches, takes the
/// registry's first entry: `left` for the horizontal one, `center` for the
/// vertical one (its registry is built in the order center, top, bottom).
enum class TextHorizontalAlign
{
    Left,
    Center,
    Right,
};

enum class TextVerticalAlign
{
    Bottom,
    Center,
    Top,
};

TextHorizontalAlign ParseTextHorizontalAlign(std::string_view word);
TextVerticalAlign   ParseTextVerticalAlign(std::string_view word);
std::string_view    TextHorizontalAlignWord(TextHorizontalAlign align);
std::string_view    TextVerticalAlignWord(TextVerticalAlign align);

struct TextLayerState {
    std::string          text;
    std::string          layer_key;
    std::string          font_key;
    std::string          resolved_font_kind { "system" };
    std::string          resolved_font_identity;
    std::string          resolved_font_path;
    // The PostScript name of the face to open in `resolved_font_path`, for a file
    // that holds several (a collection). Empty opens the file's first face.
    std::string          resolved_font_face;
    // How the face stands in for the font the scene names, for a stand-in of a Windows
    // font that is not installed: the size its glyphs are drawn at and the line metrics
    // its rows are set in. A face that is what it says it is leaves this alone.
    SystemFontFit        resolved_font_fit;
    SharedFontData       resolved_font_data;
    float                point_size { 12.0f };
    // The margin the card keeps clear around the text on each axis, in pixels.
    // This is `authored_padding` while Wallpaper Engine applies it -- the layer has
    // a visible effect pass, a colour blend or an opaque background -- and zero on
    // a plain text layer. Which effects are visible changes while a scene runs, so
    // the runtime switches it (`TextLayer::SetPaddingApplies`).
    Eigen::Vector2f      padding { Eigen::Vector2f::Zero() };
    // The padding the scene file gives, capped like `padding`, whether or not the
    // layer has the margin now. Set by the parser, for the runtime to switch
    // `padding` between this and zero.
    Eigen::Vector2f      authored_padding { Eigen::Vector2f::Zero() };
    // Whether `padding` is `authored_padding` or zero.
    bool                 padding_applies { true };
    // The authored `spacing`: pixels added to every glyph's advance (x) and to
    // the line pitch (y), at the rasterised size.
    Eigen::Vector2f      spacing { Eigen::Vector2f::Zero() };
    Eigen::Vector3f      color { Eigen::Vector3f::Ones() };
    float                alpha { 1.0f };
    float                brightness { 1.0f };
    // The words `horizontalalign` and `verticalalign` take, read through
    // `ParseTextHorizontalAlign` and `ParseTextVerticalAlign`.
    std::string          horizontal_align { "center" };
    std::string          vertical_align { "center" };
    float                max_width { 0.0f };
    uint32_t             max_rows { 0 };
    bool                 limit_width { false };
    bool                 limit_rows { false };
    bool                 use_ellipsis { false };
    // `blockalign`: rows that end at a word wrap are justified to `max_width`.
    bool                 block_align { false };
    TextStyle            style;
    bool                 dirty { false };
    bool                 cache_dirty { false };
    bool                 full_dirty { false };
    bool                 layout_pending { false };
    uint64_t             cache_revision { 0 };
    std::string          texture_cache_key;
    std::string          render_backend { "runtime-rgba-texture" };
};

/// How a text layer's text lies in its card, as Wallpaper Engine lays it out, measured
/// from the layer's own state and nothing else: the scene file's `size` is the editor's
/// box and takes no part. Layout space has the pen origin at x = 0 and the first row's
/// baseline at y = 0, y up; rows step down by `pitch`.
struct TextLayerLayout {
    // The ink and the pen at every glyph start, so `min_x <= 0 <= max_x`.
    float min_x { 0.0f };
    float max_x { 0.0f };
    // The tallest of the face's ascender and the ink above the first baseline, and the
    // lowest of the last row's line bottom and the ink below it. Zero with no text.
    float top { 0.0f };
    float bottom { 0.0f };
    // The primary face's ascender and descender in whole pixels (the descender as a
    // distance below the baseline, so not negative) and the line pitch, the face's line
    // height plus the layer's `spacing` y: what the vertical alignment measures from.
    float ascender { 0.0f };
    float descender { 0.0f };
    float pitch { 0.0f };
    // Rows laid out: a line break with nothing after it adds none, an empty line
    // between two adds one. Zero with no text, so the gaps between rows are
    // `rows - 1` only where there is text (unsigned: it wraps from zero).
    uint32_t rows { 0 };
    // The margin kept clear around the block on each axis, already gated and capped
    // (`TextLayerState::padding`).
    Eigen::Vector2f padding { Eigen::Vector2f::Zero() };
    // The block plus twice the padding, never under a pixel; 2 by 2 plus twice the
    // padding with no text. This is the layer's size.
    Eigen::Vector2f card { Eigen::Vector2f::Zero() };
    // Where the card's centre lies from the layer's origin, y up, along the layer's own
    // axes. The layer's alignment is this and nothing else: the origin sits on the edge
    // of the block the text is aligned to (the left, middle or right of it across, and
    // the ascender line, the middle of the rows or the last row's descender line down),
    // and the padding grows the card outward from there. The node is not moved by it.
    Eigen::Vector2f centre { Eigen::Vector2f::Zero() };

    Eigen::Vector2f BlockSize() const { return { max_x - min_x, top - bottom }; }
};

/// Wallpaper Engine's text `anchor`: pins the layer to an edge or corner of the
/// area the display actually shows, which is smaller or larger than the scene's
/// canvas when the display's shape differs from it. It is separate from the
/// layer's horizontal and vertical alignment, which place the text around the
/// layer's own origin.
enum class TextScreenAnchor
{
    None,
    Center,
    Top,
    TopRight,
    Right,
    BottomRight,
    Bottom,
    BottomLeft,
    Left,
    TopLeft,
};

/// How far the presented area reaches into the scene's canvas on each side, in
/// scene units: positive where the canvas is cropped, negative where the display
/// shows more than the canvas. All zero when the display shows the canvas as is.
struct PresentedMargins {
    float left { 0.0f };
    float top { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };

    bool operator==(const PresentedMargins&) const = default;
};

/// The anchor named by a scene file; anything unnamed is `None`.
TextScreenAnchor ParseTextScreenAnchor(std::string_view name);

/// The shift an anchor adds to where the layer is drawn, a translation in the scene's
/// own axes, y up (`SceneNode::SetDrawOffset`): the layer follows the edge or corner of
/// the presented area it is pinned to, and nothing parented to it or read from its origin
/// moves.
Eigen::Vector2f TextScreenAnchorOffset(TextScreenAnchor anchor, const PresentedMargins& margins);

struct TextLayerRenderBounds {
    float left { 0.0f };
    float right { 0.0f };
    float bottom { 0.0f };
    float top { 0.0f };
};

struct TextLayerRenderFrame {
    TextLayerRenderBounds bounds;
    Eigen::Vector2f       size { Eigen::Vector2f::Zero() };
    Eigen::Vector2f       center { Eigen::Vector2f::Zero() };
};

class TextLayer {
public:
    explicit TextLayer(TextLayerState state);
    /// A layer whose text the caller has laid out already: `layout` is
    /// `MeasureTextLayerLayout(state)`, so the layer does not measure it again.
    TextLayer(TextLayerState state, TextLayerLayout layout);

    const TextLayerState&  state() const { return m_state; }
    const TextLayerLayout& layout() const { return m_layout; }
    const std::string&     text() const { return m_state.text; }
    /// The card the text is laid out in.
    Eigen::Vector2f        size() const { return m_layout.card; }
    /// The card and the room the style reaches on every side: the raster's size.
    Eigen::Vector2f        rasterSize() const;
    TextLayerRenderBounds renderBounds() const;
    bool                  dirty() const { return m_state.dirty; }
    bool                  layoutPending() const { return m_state.layout_pending; }

    void SetText(std::string text);
    // What a script changes about how the text is set, as `thisLayer.pointsize`,
    // `.font` and `.horizontalalign` / `.verticalalign` do. Each one that
    // changes anything schedules a new layout and raster, as new text does.
    void SetPointSize(float point_size);
    void SetFont(std::string font_key, std::string kind, std::string identity, std::string path,
                 std::string face, SystemFontFit fit, SharedFontData data);
    void SetAlignment(std::string horizontal, std::string vertical);
    /// Gives the card its authored padding or takes it away, as Wallpaper Engine does when
    /// the layer's effects are switched on or off: the card is laid out again. Nothing
    /// changes for a state the layer already has.
    void SetPaddingApplies(bool applies);
    bool ApplyPreparedLayout(uint64_t revision, TextLayerLayout layout);
    void ClearDirty();

private:
    void Relayout();
    void EnsureCacheIdentity();
    void MarkCacheDirty();

    TextLayerState  m_state;
    TextLayerLayout m_layout;
    uint64_t        m_prepared_revision { 0 };
};

/// How far the outline, blur and shadow reach past the text on each side, in
/// pixels. The raster is this much larger than the card on every side, and the
/// card the layer draws grows with it, so nothing is cut off at the layout box.
float TextStyleMargin(const TextLayerState& state);

Eigen::Vector2f EstimateTextLayerSize(std::string_view text, float point_size, float padding);
/// Lays the text out: the block of ink, the face's ascender, descender and pitch, and
/// the card around them.
TextLayerLayout MeasureTextLayerLayout(const TextLayerState& state);
/// The card of `MeasureTextLayerLayout`.
Eigen::Vector2f MeasureTextLayerSize(const TextLayerState& state);
/// The raster of a laid-out text: its card and the room the style reaches on every side.
Eigen::Vector2f TextLayerRasterSizeForLayout(const TextLayerState& state,
                                             const TextLayerLayout& layout);
Eigen::Vector2f TextLayerRasterSize(const TextLayerState& state);
/// Where the quad of a laid-out text lies from the layer's origin: the card, centred
/// where the layout puts it, and the room the style reaches on every side.
TextLayerRenderBounds TextLayerRenderBoundsForLayout(const TextLayerState& state,
                                                     const TextLayerLayout& layout);
TextLayerRenderFrame TextLayerRenderFrameForLayout(const TextLayerState& state,
                                                   const TextLayerLayout& layout);
/// The texels of the buffers a text card is drawn into: Wallpaper Engine builds them as the
/// card's width and height with the fraction cut off, and at least 4 each. Every buffer
/// built for a card, as the scene loads and again when the card changes, takes its size
/// from here, so that none rounds where another cuts.
std::array<int32_t, 2> TextCardTexelExtent(Eigen::Vector2f card);
/// The most texels a side of the buffers an effect chain draws into holds. Wallpaper Engine
/// has no limit of its own on them; a card past this is drawn cut off to it, centred.
constexpr int32_t kTextEffectExtentLimit = 4096;
/// The buffers the effect chain of a text layer draws into, as a frame: `TextCardTexelExtent`
/// of the card (at most `kTextEffectExtentLimit`) wide and tall, centred on the card. They are
/// the card and nothing wider, so the chain's texture coordinates 0 to 1 span the card, and
/// the final card that puts the chain's result on the scene is this frame with the whole of
/// the buffer on it.
TextLayerRenderFrame TextLayerEffectFrame(const TextLayerRenderFrame& card);
/// Where the card lies in the raster of a laid-out text, as the fraction of the raster that lies
/// outside the card on each side: the raster holds the card with the room the style reaches on
/// every side, so the card begins that far in. Zero for a text with no style.
Eigen::Vector2f TextCardInsetInRaster(const TextLayerState& state, const TextLayerLayout& layout);
std::string     TextTextureName(std::string_view layer_key);
void            RasterizeTextLayer(const TextLayerState& state, uint32_t width, uint32_t height,
                                   std::vector<uint8_t>& rgba);
#ifdef WESCENE_BUILD_TESTS
uint64_t        TextLayerMeasurementCountForTests();
void            ResetTextLayerMeasurementCountForTests();
/// The layout of the boxes a layer is laid out in where no font opens, which no machine
/// with a font reaches: 0.9 em of ascender, 0.3 em of descender, 1.2 em of line.
TextLayerLayout TextLayerBoxLayoutForTests(const TextLayerState& state);
/// The boxes of that layout painted into an RGBA raster of `width` by `height`, as the
/// text is where no font opens.
void            RasterizeTextLayerBoxesForTests(const TextLayerState& state, uint32_t width,
                                                uint32_t height, std::vector<uint8_t>& rgba);
/// What the font faces have cost since `ResetTextFontCacheForTests`, which also drops
/// every face the cache holds: font files opened (a face found in the cache is not
/// one), glyph-fallback faces asked for (one per layout that lacks a glyph), and
/// faces the cache holds now.
uint64_t        TextFontFilesOpenedForTests();
uint64_t        TextFallbackFaceRequestsForTests();
std::size_t     TextFontFacesCachedForTests();
/// Whether every face the cache holds reads from its file (a mapping, as FreeType opens
/// one) and not from a copy of the font in memory.
bool            TextFontFacesAreReadFromFilesForTests();
void            ResetTextFontCacheForTests();
#endif

} // namespace wallpaper
