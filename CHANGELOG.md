# Changelog

Every published version, newest first. Each section is written when its version is
cut, by [`scripts/release_notes.py`](scripts/release_notes.py) from the commits
between two version tags: a language model writes them up for users, where older
sections list the commits. From 1.5.7, each section states the same notes in English,
Simplified Chinese and Korean; earlier sections keep their original translations.
The app's What's New window offers all three languages, with English as the fallback
for older releases without Korean notes. The GitHub Release body repeats only the
English notes. See
[docs/release.md](docs/release.md) for how a version is cut.

## 1.6.2 — 2026-10-24

### English

#### Fixed

- Long names on narrow Quick Settings tiles now shrink slightly to fit instead of being cut off with an ellipsis

### 简体中文

#### 修复

- 快捷设置磁贴较窄时，较长的名称现在会略微缩小以完整显示，不再被省略号截断

### 한국어

#### 수정됨

- 빠른 설정 타일이 좁을 때 긴 이름이 말줄임표로 잘리지 않고 살짝 작아져 전체가 표시됩니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.6.1...v1.6.2

## 1.6.1 — 2026-10-24

### English

Each desktop can now have its own wallpaper and the library can live on an external drive, and Mission Control pictures no longer fill the disk on macOS 26 and later

#### Breaking changes

- The app now sends one daily count that it ran, with its version but no install ID, even when Send performance data is off

#### New

- Each desktop (Space) can now play a wallpaper or playlist of its own and resumes where you left it, off by default and turned on in Quick Settings
- The wallpaper library and downloads can now live on an external drive, moved from Storage in Settings, with new downloads going straight there

#### Improved

- Report on GitHub now opens a bug report form with the wallpaper, app version and any error filled in, and asks what happened and what you expected

#### Fixed

- Mission Control pictures no longer fill the disk on macOS 26 and later, since the app now retakes them only when a display's wallpaper changes
- Aerial, dynamic and other moving macOS wallpapers come back as you left them when you quit, instead of a still picture on every desktop
- Muted scene wallpapers stay silent while they load, instead of playing a moment of music when a playlist switches to them
- Video wallpapers with a sound track loop smoothly instead of freezing for about a quarter of a second at each seam
- Scene layers that drew nothing now appear, such as the eyes and hair in Pastel Bloom and the alternate backgrounds some wallpapers offer
- Recoloured particles in scenes saved with newer Wallpaper Engine editors are no longer tinted twice, so the snow in The Winter Nothingness [4K] shows again
- A scene's first frame now shows with its own scaling instead of appearing fitted for a moment and then jumping to Fill
- After an update, What's New and the control panel open in front of other apps instead of hiding behind them

### 简体中文

现在每个桌面都能拥有自己的壁纸，壁纸库也可以存放在外置磁盘上，同时修复了 macOS 26 及更高版本上调度中心图片占满磁盘的问题

#### 不兼容变更

- 即使关闭了“发送性能数据”，应用现在也会每天发送一次运行计数，包含版本信息但不含安装标识

#### 新增

- 每个桌面（空间）现在可以播放各自的壁纸或播放列表，切回时从离开处继续，此功能默认关闭，可在快速设置中开启
- 壁纸库和下载内容现在可以存放在外置磁盘上，在设置的存储中即可移动，之后的新下载会直接保存到该磁盘

#### 改进

- “在 GitHub 上报告”现在会打开问题报告表单，自动填入壁纸、应用版本和错误信息，并请你描述发生了什么以及预期结果

#### 修复

- 在 macOS 26 及更高版本上，调度中心的桌面图片不再反复生成副本占满磁盘，现在仅在显示器的壁纸变化时才会更新
- 退出应用后，航拍、动态等会动的 macOS 壁纸会恢复原样，不再在每个桌面上留下一张静态图片
- 已静音的场景壁纸在加载时保持静音，播放列表切换时不再先播放片刻音乐
- 带音轨的视频壁纸现在可以平滑循环，不再在每次循环时停顿约四分之一秒
- 之前不显示的场景图层现在可以正常绘制，例如 Pastel Bloom 中人物的眼睛和头发，以及部分壁纸提供的备选背景
- 使用较新 Wallpaper Engine 编辑器保存的场景中，重新着色的粒子不再被重复着色，The Winter Nothingness [4K] 的落雪重新可见
- 场景壁纸的第一帧现在直接按其缩放方式显示，不再先短暂适应屏幕再跳到填充
- 更新后，“新功能”窗口和控制面板会显示在其他应用前面，不再被遮挡在后方

### 한국어

이제 데스크탑마다 자체 배경화면을 둘 수 있고 보관함을 외장 드라이브에 보관할 수 있으며, macOS 26 이상에서 Mission Control 사진이 디스크를 채우던 문제가 해결되었습니다

#### 호환되지 않는 변경 사항

- 이제 성능 데이터 보내기가 꺼져 있어도 앱이 실행되었다는 사실을 하루에 한 번 보내며, 앱 버전은 포함하지만 설치 ID는 포함하지 않습니다

#### 새로운 기능

- 이제 데스크탑(Space)마다 각자의 배경화면이나 재생목록을 재생하고 돌아오면 멈춘 곳부터 이어지며, 기본적으로 꺼짐 상태로 빠른 설정에서 켤 수 있습니다
- 이제 설정의 저장 공간에서 보관함과 다운로드를 외장 드라이브로 옮길 수 있으며, 이후 새 다운로드도 그 드라이브에 바로 저장됩니다

#### 개선 사항

- GitHub에 보고하기가 이제 배경화면, 앱 버전, 오류가 미리 채워진 버그 보고 양식을 열고 무슨 일이 있었는지와 기대한 결과를 묻습니다

#### 수정됨

- macOS 26 이상에서 Mission Control용 데스크탑 사진의 사본이 디스크를 채우지 않으며, 이제 디스플레이의 배경화면이 바뀔 때만 다시 찍습니다
- 앱을 종료하면 항공 영상, 다이내믹 등 움직이는 macOS 배경화면이 원래대로 돌아오며, 더 이상 모든 데스크탑에 정지 사진이 남지 않습니다
- 음소거된 씬 배경화면이 불러오는 동안에도 조용히 유지되며, 재생목록이 전환될 때 음악이 잠깐 재생되지 않습니다
- 사운드 트랙이 있는 동영상 배경화면이 반복될 때마다 약 0.25초씩 멈추지 않고 매끄럽게 반복됩니다
- Pastel Bloom의 눈과 머리카락, 일부 배경화면이 제공하는 대체 배경처럼 보이지 않던 씬 레이어가 이제 제대로 나타납니다
- 최신 Wallpaper Engine 편집기로 저장한 씬에서 색을 바꾼 파티클이 두 번 칠해지지 않아 The Winter Nothingness [4K]의 눈이 다시 보입니다
- 씬의 첫 프레임이 잠깐 화면에 맞춤으로 보였다가 채우기로 바뀌지 않고 처음부터 자체 크기 조정으로 표시됩니다
- 업데이트 후 새로운 기능 창과 제어판이 다른 앱 뒤에 숨지 않고 앞에 열립니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.6.0...v1.6.1

## 1.6.0 — 2026-10-23

### English

![WallpaperMachine 1.6.0](Resources/ReleaseBanners/1.6.0.jpg)

WallpaperMachine 1.6 draws every scene with Native Metal, hands video wallpapers to the macOS video player, uses less memory, and is now free software under the GNU GPL version 3

#### Highlights

- Native Metal now draws every scene wallpaper, and the older Compatibility renderer is gone
- Video wallpapers play through the macOS hardware video player by default, at their own frame rate, on the desktop and in the preview window
- Scenes with 10-bit and HDR videos now stay on Native Metal and show those videos tone mapped to standard range
- Scene wallpapers and the control panel use much less memory, especially when one wallpaper runs on several displays
- WallpaperMachine is now licensed under GPL-3.0-only, with the renderer it inherited rewritten from the ground up

#### Breaking changes

- The Scene renderer and Video playback choices are gone from Settings › Performance › Advanced; settings saved by earlier versions still load
- A scene Native Metal cannot draw is no longer handed to another renderer: it keeps its last picture, or shows its preview, and the reason appears under Drawn by
- Videos macOS cannot play, such as AVI files or AV1 on a Mac without hardware AV1 decoding, are refused when you apply them, with a message that names the format and how to convert it
- Fit with blurred backdrop shows black bars around plain video wallpapers; scene wallpapers keep their blurred backdrop

#### New

- Horizontal position and Vertical position now move video wallpapers that macOS plays, and Center puts them back
- The preview window plays video wallpapers with the same players as the desktop, with sound when you unmute it
- On the optional animated lock screen and in the screen saver, plain video wallpapers play through the macOS hardware video player, always without sound
- When the lock screen cannot show a scene or video, it keeps its last frame and the lock screen status in the app says why

#### Improved

- Displays showing the same scene share its pictures, saving tens to hundreds of megabytes of GPU memory for each extra display
- Videos inside scenes are read from disk instead of being copied into memory, so a 150 MB clip no longer briefly needs about 300 MB while the scene loads
- Scenes with many layers need less video memory, and 4K videos keep fewer decoded frames waiting
- The control panel lets go of thumbnails and animated previews you have scrolled past or cannot see, and a thumbnail you scroll back to appears at once
- Scenes with a clock or readout whose width keeps changing stay smooth instead of reloading the whole scene each time
- Messages about scene rendering, Energy use and the lock screen now appear in Korean

#### Fixed

- The optional animated lock screen recovers by itself when its renderer stops or a display sleeps while the Mac is locked, instead of falling back to a black or default picture
- Particle effects whose colour a scene overrides take on the right tint, so fire that should burn red no longer turns pink and magenta
- Web wallpapers built with React, such as the Bocchi the Rock! album player, no longer stay black and silent
- A background picture you choose is no longer darkened by the scene's colour, and pass-through, fullscreen and resized layers stay where they belong
- Composite layers, perspective picture layers, cover art over a composite and height fog from older Workshop packages draw as the scene describes
- Scene scripts follow Wallpaper Engine more closely for conditions, effect visibility, start-up order, sound layers and rotation
- A scene with a shader that cannot be compiled keeps its picture and names the shader, instead of drawing with a part missing
- Scenes whose scripts create layers from certain models no longer crash a few seconds in
- More Workshop wallpapers' shaders now compile for Native Metal
- The lock screen keeps working when your wallpapers are reached through a folder alias

### 简体中文

![WallpaperMachine 1.6.0](Resources/ReleaseBanners/1.6.0.zh-Hans.jpg)

WallpaperMachine 1.6 用 Native Metal 绘制所有场景，把视频壁纸交给 macOS 视频播放器，占用更少内存，并改为以 GNU GPL 第 3 版发布的自由软件

#### 亮点

- 现在所有场景壁纸都由 Native Metal 绘制，旧的兼容模式渲染器已移除
- 视频壁纸默认通过 macOS 硬件视频播放器播放，按视频自身的帧率运行，桌面和预览窗口均如此
- 含 10 位和 HDR 视频的场景现在会留在 Native Metal 上，并将这些视频色调映射到标准动态范围显示
- 场景壁纸和控制面板占用的内存大幅减少，在多台显示器上运行同一壁纸时尤为明显
- WallpaperMachine 现以 GPL-3.0-only 许可发布，继承而来的渲染器已从头重写

#### 不兼容变更

- 设置 › 性能 › 高级 中的“场景渲染器”和“视频播放”选项已移除；旧版本保存的设置仍可正常载入
- Native Metal 无法绘制的场景不再交给其他渲染器：它会保留最后一帧画面或显示预览图，原因显示在“绘制方”下
- macOS 无法播放的视频（例如 AVI 文件，或在不支持硬件 AV1 解码的 Mac 上的 AV1 视频）会在应用时被拒绝，提示信息会说明格式及转换方法
- 适应（模糊背景）在普通视频壁纸周围显示黑边；场景壁纸仍保留模糊背景

#### 新增

- 水平位置和垂直位置现在也能移动由 macOS 播放的视频壁纸，居中可将其复位
- 预览窗口使用与桌面相同的播放器播放视频壁纸，取消静音后可听到声音
- 在可选的动态锁定屏幕和屏幕保护程序中，普通视频壁纸通过 macOS 硬件视频播放器播放，且始终静音
- 锁定屏幕无法显示某个场景或视频时会保留最后一帧，应用中的锁定屏幕状态会说明原因

#### 改进

- 显示同一场景的多台显示器会共享其图片，每多一台显示器可节省数十到数百 MB 显存
- 场景中的视频直接从磁盘读取，不再整个复制到内存，150 MB 的视频在场景载入时不再短暂占用约 300 MB
- 图层众多的场景所需显存更少，4K 视频等待中的已解码帧也更少
- 控制面板会释放已滚过或看不到的缩略图和动态预览，滚回时缩略图会立即出现
- 带有宽度不断变化的时钟或读数的场景保持流畅，不再每次都重新载入整个场景
- 有关场景渲染、能耗和锁定屏幕的提示现在提供韩语版本

#### 修复

- 可选的动态锁定屏幕在渲染器停止或 Mac 锁定期间显示器休眠时会自行恢复，不再退回黑屏或默认图片
- 场景覆盖了颜色的粒子效果现在会呈现正确的色调，本应燃烧成红色的火焰不再变成粉色和品红色
- 使用 React 构建的网页壁纸（例如《孤独摇滚！》专辑播放器）不再一直黑屏无声
- 你选择的背景图片不再被场景颜色压暗，穿透、全屏和调整过大小的图层也会留在正确位置
- 合成图层、透视图片图层、合成图层上的封面以及旧版创意工坊包中的高度雾现在都按场景描述绘制
- 场景脚本在条件、效果可见性、启动顺序、声音图层和旋转方面更贴近 Wallpaper Engine
- 含有无法编译的着色器的场景会保留画面并指出是哪个着色器，不再缺少部分内容继续绘制
- 脚本用某些模型创建图层的场景不再在几秒后崩溃
- 更多创意工坊壁纸的着色器现在可以为 Native Metal 编译
- 通过文件夹替身访问壁纸时，锁定屏幕也能正常工作

### 한국어

![WallpaperMachine 1.6.0](Resources/ReleaseBanners/1.6.0.ko.jpg)

WallpaperMachine 1.6은 모든 장면을 Native Metal로 그리고, 비디오 배경화면을 macOS 비디오 플레이어에 맡기며, 메모리를 덜 사용하고, 이제 GNU GPL 버전 3을 따르는 자유 소프트웨어입니다

#### 주요 변경 사항

- 이제 모든 장면 배경화면을 Native Metal이 그리며, 이전 호환 렌더러는 제거되었습니다
- 비디오 배경화면은 기본적으로 macOS 하드웨어 비디오 플레이어로 재생되며, 데스크톱과 미리보기 창 모두에서 원래 프레임 속도로 재생됩니다
- 10비트 및 HDR 비디오가 들어 있는 장면도 이제 Native Metal에서 그려지며, 해당 비디오는 표준 다이내믹 레인지로 톤 매핑되어 표시됩니다
- 장면 배경화면과 제어판의 메모리 사용량이 크게 줄었으며, 특히 하나의 배경화면을 여러 디스플레이에서 실행할 때 효과가 큽니다
- WallpaperMachine은 이제 GPL-3.0-only 라이선스로 제공되며, 물려받은 렌더러는 처음부터 새로 작성되었습니다

#### 호환되지 않는 변경 사항

- 설정 › 성능 › 고급의 장면 렌더러 및 비디오 재생 선택 항목이 제거되었습니다. 이전 버전에서 저장한 설정은 그대로 불러옵니다
- Native Metal이 그릴 수 없는 장면은 더 이상 다른 렌더러로 넘어가지 않습니다. 마지막 화면을 유지하거나 미리보기를 보여 주며, 이유는 렌더링 방식 아래에 표시됩니다
- AVI 파일이나 하드웨어 AV1 디코딩을 지원하지 않는 Mac의 AV1 비디오처럼 macOS가 재생할 수 없는 비디오는 적용할 때 거부되며, 형식과 변환 방법을 알려 주는 메시지가 표시됩니다
- 맞춤, 흐린 배경은 일반 비디오 배경화면 주위에 검은 여백을 표시합니다. 장면 배경화면은 흐린 배경을 그대로 유지합니다

#### 새로운 기능

- 가로 위치와 세로 위치로 이제 macOS가 재생하는 비디오 배경화면도 옮길 수 있으며, 중앙을 누르면 원래 위치로 돌아갑니다
- 미리보기 창이 데스크톱과 같은 플레이어로 비디오 배경화면을 재생하며, 음소거를 해제하면 소리도 들립니다
- 선택 사항인 움직이는 잠금 화면과 화면 보호기에서 일반 비디오 배경화면이 macOS 하드웨어 비디오 플레이어로 재생되며, 소리는 항상 꺼져 있습니다
- 잠금 화면에서 장면이나 비디오를 표시할 수 없으면 마지막 프레임을 유지하고, 앱의 잠금 화면 상태에 그 이유가 표시됩니다

#### 개선 사항

- 같은 장면을 표시하는 디스플레이들이 그림을 공유하여, 디스플레이가 하나 늘어날 때마다 GPU 메모리를 수십에서 수백 MB 절약합니다
- 장면 속 비디오를 메모리에 통째로 복사하지 않고 디스크에서 바로 읽으므로, 150MB 클립이 장면을 불러오는 동안 잠깐 약 300MB를 차지하는 일이 없어졌습니다
- 레이어가 많은 장면에 필요한 비디오 메모리가 줄었고, 4K 비디오가 대기시켜 두는 디코딩된 프레임도 줄었습니다
- 제어판이 스크롤해 지나갔거나 보이지 않는 썸네일과 움직이는 미리보기를 해제하며, 다시 스크롤해 돌아온 썸네일은 즉시 나타납니다
- 폭이 계속 바뀌는 시계나 수치 표시가 있는 장면이 매번 장면 전체를 다시 불러오지 않고 부드럽게 유지됩니다
- 장면 렌더링, 에너지 사용량, 잠금 화면에 관한 메시지가 이제 한국어로 표시됩니다

#### 수정됨

- 선택 사항인 움직이는 잠금 화면이 렌더러가 멈추거나 Mac이 잠긴 동안 디스플레이가 잠자기에 들어가도 스스로 복구되며, 검은 화면이나 기본 그림으로 돌아가지 않습니다
- 장면이 색상을 덮어쓴 파티클 효과가 올바른 색조를 띠므로, 붉게 타올라야 할 불꽃이 더 이상 분홍색과 자홍색으로 변하지 않습니다
- 봇치 더 록! 앨범 플레이어처럼 React로 만든 웹 배경화면이 더 이상 검은 화면에 소리 없이 멈춰 있지 않습니다
- 직접 고른 배경 그림이 장면 색상 때문에 어두워지지 않으며, 패스스루·전체 화면·크기를 조정한 레이어도 제자리에 머뭅니다
- 합성 레이어, 원근 그림 레이어, 합성 레이어 위의 커버, 이전 창작마당 패키지의 높이 안개가 장면에 적힌 대로 그려집니다
- 장면 스크립트가 조건, 효과 표시 여부, 시작 순서, 사운드 레이어, 회전에서 Wallpaper Engine과 더 가깝게 동작합니다
- 컴파일할 수 없는 셰이더가 있는 장면은 일부가 빠진 채 그려지지 않고, 화면을 유지하며 해당 셰이더를 알려 줍니다
- 스크립트가 특정 모델로 레이어를 만드는 장면이 몇 초 뒤 충돌하지 않습니다
- 더 많은 창작마당 배경화면의 셰이더가 이제 Native Metal용으로 컴파일됩니다
- 폴더 별칭을 통해 배경화면에 접근하는 경우에도 잠금 화면이 제대로 동작합니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.5.9...v1.6.0

## 1.5.9 — 2026-10-21

### English

This update lets fitted wallpapers fill empty screen space with a blurred backdrop and makes music-player scenes and multi-display setups behave more reliably

#### New

- Scene and video wallpapers can now fit the whole picture on screen and fill the space around it with a soft blurred copy instead of black bars

#### Fixed

- Each display keeps its own wallpaper when macOS switches the main display, without reloading, flashing or jumping onto a monitor you switched off
- Some scene wallpapers that showed only a grey background now draw their full picture
- Scripted music players in scene wallpapers stay in one piece and remain on screen instead of breaking apart and fading away
- Album covers and their shadows in music-player wallpapers stay on their 3D model when the mouse moves or the album tilts
- Music-player wallpapers show their default album art until a track plays, so blurred backgrounds and cover fades no longer stay flat grey
- Wallpapers with a background for each screen shape show only the one you chose, and the cover fade now plays on every new track
- Audio visualizer bars in some music wallpapers now move with the music instead of staying flat

### 简体中文

本次更新让适应屏幕的壁纸可以用模糊背景填满空白区域，并让音乐播放器场景壁纸和多显示器设置更加稳定可靠

#### 新增

- 场景和视频壁纸现在可以完整显示画面，并用柔和的模糊副本填充周围空白，而不再显示黑边

#### 修复

- macOS 切换主显示器时，每台显示器都会保留自己的壁纸，不再重新载入、闪烁或出现在已关闭壁纸的显示器上
- 部分原本只显示灰色背景的场景壁纸现在可以完整显示画面
- 场景壁纸中带脚本的音乐播放器现在保持完整并持续显示，不再散开或逐渐消失
- 音乐播放器壁纸中的专辑封面及其阴影在鼠标移动或专辑倾斜时会始终贴合 3D 模型
- 音乐播放器壁纸在播放曲目前会显示默认专辑封面，模糊背景和封面淡入效果不再停留在单调的灰色
- 为不同屏幕比例准备了背景的壁纸现在只显示所选比例的背景，切换曲目时封面淡入效果也能正常播放
- 部分音乐壁纸中的音频可视化条现在会随音乐跳动，不再一直静止

### 한국어

이번 업데이트에서는 화면에 맞춘 배경화면의 빈 공간을 흐린 배경으로 채울 수 있으며, 음악 플레이어 장면과 다중 디스플레이 환경이 더 안정적으로 동작합니다

#### 새로운 기능

- 이제 장면 및 비디오 배경화면을 화면에 전체로 맞추고 주변 공간을 검은 여백 대신 부드럽게 흐린 사본으로 채울 수 있습니다

#### 수정됨

- macOS에서 주 디스플레이가 바뀌어도 각 디스플레이가 자기 배경화면을 유지하며, 다시 불러오거나 깜박이거나 꺼 둔 모니터로 옮겨가지 않습니다
- 회색 배경만 보이던 일부 장면 배경화면이 이제 전체 화면을 제대로 그립니다
- 장면 배경화면의 스크립트 음악 플레이어가 흩어지거나 사라지지 않고 온전한 모습으로 화면에 계속 표시됩니다
- 음악 플레이어 배경화면의 앨범 커버와 그림자가 마우스를 움직이거나 앨범이 기울어져도 3D 모델 위에 그대로 붙어 있습니다
- 음악 플레이어 배경화면이 곡을 재생하기 전까지 기본 앨범 아트를 보여 주므로 흐린 배경과 커버 전환이 더 이상 회색으로 남지 않습니다
- 화면 비율별 배경이 있는 배경화면은 선택한 비율의 배경만 보여 주며, 새 곡마다 커버 전환 효과가 재생됩니다
- 일부 음악 배경화면의 오디오 시각화 막대가 이제 멈춰 있지 않고 음악에 맞춰 움직입니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.5.8...v1.5.9

## 1.5.8 — 2026-10-20

### English

This update brings scene wallpapers closer to how they look in Wallpaper Engine and makes the Steam Workshop clearer when Steam is busy

#### Fixed

- Scene wallpapers show their lighting, height fog, rotating models and blur effects again, including wallpapers from older Workshop packages
- Steam Workshop and Collections now retry on their own when Steam is busy and say so, instead of wrongly claiming Steam changed its page
- Wallpapers that use frosted noise or audio line effects display those layers again instead of leaving them out

### 简体中文

本次更新让场景壁纸的效果更接近 Wallpaper Engine，并在 Steam 繁忙时给出更清楚的 Steam 创意工坊提示

#### 修复

- 场景壁纸重新正确显示光照、高度雾、模型旋转和模糊效果，较旧的创意工坊壁纸包也同样适用
- Steam 繁忙时，Steam 创意工坊和合集会自动重试并如实提示，不再误报 Steam 页面已更改
- 使用磨砂噪点或音频线条效果的壁纸，现在会重新显示这些图层，不再缺失

### 한국어

이번 업데이트로 장면 배경화면이 Wallpaper Engine에서 보이는 모습에 더 가까워지고, Steam이 혼잡할 때 Steam 창작마당 안내가 더 명확해집니다

#### 수정됨

- 장면 배경화면에서 조명, 높이 안개, 모델 회전, 흐림 효과가 다시 표시되며 오래된 창작마당 패키지의 배경화면도 마찬가지입니다
- Steam이 혼잡하면 Steam 창작마당과 컬렉션이 자동으로 다시 시도하고 그 상황을 알려 주며, 더 이상 Steam 페이지가 바뀌었다고 잘못 안내하지 않습니다
- 서리 낀 노이즈나 오디오 라인 효과를 쓰는 배경화면에서 해당 레이어가 빠지지 않고 다시 표시됩니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.5.7...v1.5.8

## 1.5.7 — 2026-10-19

### English

WallpaperMachine now speaks Korean, and sunrise and sunset rules and Steam sign-in take less setup

#### New

- The control panel, settings, menus, dialogs and lock screen are now available in Korean, following your macOS language or chosen in the language setting
- What's New shows release notes in Korean when the app uses Korean, with English shown for older releases
- Import every subscribed Workshop wallpaper missing from your library straight from the Steam page of the welcome guide
- Sunrise and sunset rules can now switch at two fixed clock times you choose, with rule offsets still applied
- A new Automatic option lets sunrise and sunset follow your Mac's approximate location, with a link to System Settings if access is refused

#### Improved

- Your Steam Community sign-in now survives quitting the app and renews itself, so Your subscriptions should not ask you to sign in again for months
- Scene and web wallpapers show the current track without an extra opt-in, while choices you already saved are kept

#### Fixed

- A second display resumes its wallpaper after wake or unlock without needing a click or refresh
- Applying a scene wallpaper before shared scene resources are installed opens their setup instead of failing with an error
- The Dock icon stays while the control panel is minimized or a Steam or pixiv sign-in window is open, so the panel can be brought back
- Restoring a backup keeps your sunrise and sunset settings intact, including backups made by older versions

### 简体中文

WallpaperMachine 现已支持韩语，日出日落规则和 Steam 登录也更省心

#### 新增

- 控制面板、设置、菜单、对话框和锁定屏幕现已支持韩语，可跟随 macOS 语言，也可在语言设置中选择
- 应用语言为韩语时，新功能窗口会显示韩语更新说明，较早的版本则显示英文
- 在欢迎向导的 Steam 页面中，可直接导入壁纸库里还没有的所有已订阅创意工坊壁纸
- 日出日落规则现在可以按你设定的两个固定时间切换，规则的时间偏移依然生效
- 新增“自动”选项，日出日落时间可跟随 Mac 的大致位置；若位置访问被拒绝，会提供前往系统设置的链接

#### 改进

- Steam 社区的登录状态现在退出应用后仍会保留并自动续期，“我的订阅”数月内通常无需重新登录
- 场景和网页壁纸无需额外开启即可显示当前播放的曲目，已保存的设置保持不变

#### 修复

- 唤醒或解锁后，第二台显示器上的壁纸会自动继续播放，无需点击或刷新
- 在共享场景资源安装前应用场景壁纸，现在会打开资源安装步骤，而不是报错失败
- 控制面板最小化或 Steam、pixiv 登录窗口仍打开时，Dock 图标不再消失，面板可以照常恢复
- 恢复备份时会完整保留日出日落设置，包括旧版本创建的备份

### 한국어

WallpaperMachine이 이제 한국어를 지원하며, 일출·일몰 규칙과 Steam 로그인도 더 간편해졌습니다

#### 새로운 기능

- 제어판, 설정, 메뉴, 대화상자와 잠금 화면을 이제 한국어로 사용할 수 있으며, macOS 언어를 따르거나 언어 설정에서 선택할 수 있습니다
- 앱 언어가 한국어이면 새로운 기능 창에 한국어 릴리스 노트가 표시되며, 이전 버전은 영어로 표시됩니다
- 시작 가이드의 Steam 페이지에서 보관함에 없는 구독한 창작마당 배경화면을 모두 바로 가져올 수 있습니다
- 일출·일몰 규칙이 이제 직접 지정한 두 고정 시각에 전환할 수 있으며, 규칙의 시간 오프셋도 그대로 적용됩니다
- 새 자동 옵션으로 일출·일몰이 Mac의 대략적인 위치를 따르며, 위치 접근이 거부되면 시스템 설정으로 가는 링크가 표시됩니다

#### 개선 사항

- Steam 커뮤니티 로그인이 이제 앱을 종료해도 유지되고 자동으로 갱신되어, 내 구독을 보려고 몇 달 동안 다시 로그인하지 않아도 됩니다
- 장면 및 웹 배경화면이 별도로 켜지 않아도 현재 재생 중인 곡을 표시하며, 이미 저장한 설정은 그대로 유지됩니다

#### 수정됨

- 잠자기나 잠금을 해제한 뒤 두 번째 디스플레이의 배경화면이 클릭이나 새로 고침 없이 다시 재생됩니다
- 공유 장면 리소스를 설치하기 전에 장면 배경화면을 적용하면 오류 대신 리소스 설치 화면이 열립니다
- 제어판이 최소화되어 있거나 Steam 또는 pixiv 로그인 창이 열려 있으면 Dock 아이콘이 유지되어 제어판을 다시 열 수 있습니다
- 백업을 복원할 때 이전 버전에서 만든 백업을 포함해 일출·일몰 설정이 그대로 유지됩니다

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.5.6...v1.5.7

## 1.5.6 — 2026-10-17

### English

This update makes more scene wallpapers look the way they do in Wallpaper Engine, fixes a problem that could stop the app from quitting, and adds a way to reset all settings

#### New

- Settings › General has a new Reset section that, after a confirmation, returns every setting to its default while keeping your library, playlists, collections and sign-ins

#### Improved

- A wide window now shows the target display's name in the toolbar, so you can see at a glance which screen gets wallpapers
- Wallpaper details now slide in and out from the window's right edge, matching the Filters sidebar

#### Fixed

- Quitting WallpaperMachine no longer fails with a missing-file error when the desktop picture you used before it has since been deleted
- Scenes and Workshop presets with a chosen background picture now show that picture instead of turning the whole wallpaper black
- Full-screen effects inside a group, such as the CRT screen of terminal wallpapers, no longer show a shrunken or shifted copy of the scene
- Moving the mouse no longer makes wallpapers with a full-screen post-processing layer, such as film grain, show the picture twice
- Clock widgets and other layers that zoom on hover no longer disappear right after a wallpaper starts
- Wallpaper settings chosen from a list, such as a clock's date format, now follow your choice instead of always showing the same option
- Resized animated picture layers now appear at their saved size, so the CRT monitor in Makima is Listening fills its bezel without a grey border
- On the Compatibility renderer, effects that build on the previous frame, such as fluid simulations, no longer start from a bright screen on some Macs

### 简体中文

本次更新让更多场景壁纸的显示效果与 Wallpaper Engine 一致，修复了可能导致应用无法退出的问题，并新增了重置全部设置的功能

#### 新增

- 设置 › 通用新增“重置”部分，确认后可将所有设置恢复为默认值，同时保留你的壁纸库、播放列表、合集和登录信息

#### 改进

- 窗口较宽时，工具栏会显示目标显示器的名称，一眼就能看出壁纸将应用到哪块屏幕
- 壁纸详情栏现在会从窗口右侧滑入滑出，与筛选边栏的动画保持一致

#### 修复

- 如果使用 WallpaperMachine 之前的桌面图片已被删除，退出应用时不再因找不到文件而失败
- 选择了背景图片的场景或自带背景图片的创意工坊预设现在会正常显示该图片，不再整屏发黑
- 图层组内的全屏效果（如终端类壁纸的 CRT 屏幕效果）不再显示缩小或错位的场景画面
- 带有全屏后期处理图层（如胶片颗粒）的壁纸在移动鼠标时不再出现画面重影
- 时钟等悬停时会放大的小部件不再在壁纸启动后立即消失
- 从列表中选择的壁纸设置（如时钟的日期格式）现在会按你的选择生效，不再始终显示同一选项
- 调整过大小的动态图片图层现在按场景保存的尺寸显示，Makima is Listening 中的 CRT 显示器屏幕会填满边框，不再留有灰边
- 使用兼容渲染器时，流体模拟等基于上一帧的效果在部分 Mac 上不再从全亮画面开始

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.5.5...v1.5.6

## 1.5.5 — 2026-10-17

### English

![WallpaperMachine 1.5.5](Resources/ReleaseBanners/1.5.5.jpg)

This release rebuilds the control panel as a native macOS window and brings scene wallpapers much closer to how they look and behave in Wallpaper Engine

#### Highlights

- The control panel is now a native macOS window, with tabs in the title bar, a sliding Filters sidebar and a Now Playing bar
- Scenes now show their lights, distance and height fog, camera shake and light shafts, as they do in Wallpaper Engine
- 2D scene wallpapers are drawn at your display's resolution by default, so edges and fine detail stay sharp
- Text, particles, ripples and media widgets in scenes look and behave much closer to Wallpaper Engine

#### Breaking changes

- Clicking a tag chip in Filters now shows only wallpapers with that tag; to hide a tag, Option-click it or choose Hide this tag

#### New

- Library, Steam Workshop, pixiv and Settings are tabs in the title bar, and what is playing sits in a bar along the bottom
- Filters open in a sidebar that slides out beside the grid, and collections are created, renamed and deleted in its Collections group
- Settings is laid out like System Settings, with a search that finds any setting, Quick Settings tiles and new icons
- Point, spot, tube and directional lights now light the layers and 3D models of scenes that use them
- Distance and height fog now appear in scenes that use them
- Camera shake now works in scenes that ask for it, following the wallpaper's own settings
- Text layers now show their outline, blur and drop shadow
- Light shafts made with the Wallpaper Engine editor's shape objects now appear in scenes
- A new 2D scene resolution choice in Performance settings lets you draw at canvas size instead, using less GPU time and memory
- Scene scripts get much more of Wallpaper Engine 2.8's scripting, so more interactive wallpapers and widgets run as their authors intended
- Steam Workshop wallpapers have a Share button in their details, and About adds Share WallpaperMachine and Star on GitHub
- You can choose to send a small daily performance report that helps find slow wallpapers and crashes; it stays off until you turn it on
- The What's New window shows a banner and highlights for feature releases, in the language you read the notes in

#### Improved

- Scrolling the wallpaper grids stays smooth, even with animated previews playing or the details column open
- Quick Settings now says which battery, Low Power Mode or heat rule is pausing wallpapers or lowering quality, and Performance shows the frame rate in force
- Particle effects such as snow, leaves and stars start fully populated, scale with their layer and spawn where Wallpaper Engine puts them
- Camera parallax now moves at Wallpaper Engine's speed, and clocks, labels and composited layers move in step with the layers around them
- Bloom, HDR and layer brightness follow Wallpaper Engine's rules and defaults, so glowing scenes look closer to the original
- Large pictures in scenes are drawn from their full-size image, so they no longer look soft on high-resolution displays
- Clocks and other changing text update promptly instead of reloading their fonts every time
- Wallpaper settings bound to a scene's bloom, parallax or zoom now take effect while the wallpaper runs
- More scenes now stay on the Native Metal renderer instead of switching to Compatibility
- The title bar shows WallpaperMachine and its version again, each page has its search bar at the top, and filter groups fold smoothly

#### Fixed

- Text layers in scenes now use the right fonts, size, alignment and spacing, with no dark edges, and stay visible under effects
- Cursor ripple and fluid effects now move, getting one push per click instead of one every frame the button is held
- Media widgets hide while nothing is playing, show their cover art, and tell a playing track from a paused one
- Layers animated in size, rotation or colour now move and change as they do in Wallpaper Engine
- Dragging on a web wallpaper no longer drops a copy of its picture onto the desktop or stops Finder from selecting icons
- Web audio visualizers such as osu!flower Enhanced now start and react to sound
- Clicking in another window, the menu bar or the Dock no longer counts as a click on the scene wallpaper behind it
- With Only play on the display I'm using on, other displays keep playing while a full-screen app covers your current display
- A video inside a scene no longer jumps back to its start or freezes when a clock drawn over it changes
- AV1 videos inside scene wallpapers play again
- Workshop effects that drew nothing, such as audio bars, colour grading, shadow and fluid simulation, now show
- Pictures under a post-processing layer now fill the frame, and such layers no longer show a displaced copy of the screen
- Lit 3D models no longer show sparkles or hard highlights, glows stay behind the models in front of them, and heads follow the cursor correctly
- Layers that blend with the screen no longer vanish or appear upside down, and layers tied to a wallpaper's choices or scripts show when they should
- Paused, resumed or finished downloads update at once in the Downloads list, and Chinese download progress shows its percent sign
- Searching Settings no longer leaves the contents of an open section showing without its title

### 简体中文

![WallpaperMachine 1.5.5](Resources/ReleaseBanners/1.5.5.zh-Hans.jpg)

本版本将控制面板重建为原生 macOS 窗口，并让场景壁纸的外观和表现更接近 Wallpaper Engine

#### 亮点

- 控制面板现为原生 macOS 窗口，标题栏中设有标签页，并配有可滑出的筛选侧栏和“正在播放”栏
- 场景壁纸现在会呈现光源、距离雾与高度雾、镜头抖动和光束，和在 Wallpaper Engine 中一样
- 2D 场景壁纸默认按显示器分辨率渲染，边缘和细节更加清晰
- 场景中的文字、粒子、涟漪和媒体小组件，外观和表现都更接近 Wallpaper Engine

#### 不兼容变更

- 在筛选中点按标签现在只显示带有该标签的壁纸；如需隐藏某个标签，请按住 Option 点按或选择“隐藏此标签”

#### 新增

- 壁纸库、Steam 创意工坊、pixiv 和设置以标签页形式位于标题栏，正在播放的壁纸显示在窗口底部的栏中
- 筛选条件显示在网格旁滑出的侧栏中，可在其中的“合集”分组里新建、重命名和删除合集
- 设置采用与系统设置相同的布局，可搜索任意设置项，并提供快捷设置磁贴和全新图标
- 使用点光源、聚光灯、管状光源或平行光的场景，现在会照亮其中的图层和 3D 模型
- 设有距离雾或高度雾的场景现在会显示雾效
- 需要镜头抖动的场景现在会按壁纸自身的设置抖动镜头
- 文字图层现在会显示描边、模糊和投影
- 用 Wallpaper Engine 编辑器形状对象制作的光束现在会显示在场景中
- 性能设置新增 2D 场景分辨率选项，可改为按画布尺寸渲染，占用更少的 GPU 时间和内存
- 场景脚本支持更多 Wallpaper Engine 2.8 的脚本功能，更多交互式壁纸和小组件可按作者的设计运行
- Steam 创意工坊壁纸的详情中新增“分享”按钮，“关于”中新增分享 WallpaperMachine 和在 GitHub 上加星标
- 可选择每天发送一份简短的性能报告，帮助发现运行缓慢的壁纸和崩溃问题；此功能在你开启前保持关闭
- “新功能”窗口会为功能版本显示横幅和亮点，并使用你阅读说明时所选的语言

#### 改进

- 滚动壁纸网格更加流畅，即使正在播放动态预览或打开了详情栏也不卡顿
- 快捷设置现在会说明是哪条电池、低电量模式或过热规则暂停了壁纸或降低了画质，性能页也会显示当前生效的帧率
- 雪花、落叶、星光等粒子效果一开始即已铺满，随图层缩放，并在与 Wallpaper Engine 相同的位置生成
- 镜头视差现在以 Wallpaper Engine 的速度移动，时钟、文字标签和合成图层会与周围图层同步移动
- 泛光、HDR 和图层亮度遵循 Wallpaper Engine 的规则与默认值，发光场景更接近原作效果
- 场景中的大尺寸图片改用原尺寸图像绘制，在高分辨率显示器上不再显得模糊
- 时钟等不断变化的文字不再每次都重新载入字体，刷新更加及时
- 绑定到场景泛光、视差或缩放的壁纸属性，现在在壁纸运行时即可生效
- 更多场景现在会继续使用原生 Metal 渲染器，而不再切换到兼容渲染器
- 标题栏重新显示 WallpaperMachine 及其版本号，每个页面顶部都有搜索栏，筛选分组的展开和收起也更顺滑

#### 修复

- 场景中的文字图层现在使用正确的字体、大小、对齐和间距，边缘不再发黑，套用效果后也不会消失
- 鼠标涟漪和流体效果现在会动起来，每次点按推动一次，而不是按住时每帧都推动
- 没有播放内容时媒体小组件会自动隐藏，显示其封面图，并能正确区分播放和暂停
- 设有缩放、旋转或颜色动画的图层现在会像在 Wallpaper Engine 中一样动起来
- 在网页壁纸上拖移时，不再会把图片拷贝到桌面，也不再影响在访达中框选图标
- osu!flower Enhanced 等网页音频可视化壁纸现在能正常启动并随声音变化
- 在其他窗口、菜单栏或程序坞中点按，不再被当作对后方场景壁纸的点按
- 开启“仅在我正在使用的显示器上播放”后，当前显示器被全屏 App 遮挡时，其他显示器会继续播放
- 场景中的视频不再因上方的时钟变化而跳回开头或卡住
- 场景壁纸中的 AV1 视频恢复播放
- 音频柱、调色、阴影、流体模拟等此前不显示的创意工坊效果现在可以正常显示
- 后期处理图层下的图片现在会铺满画面，这类图层也不再显示错位的屏幕副本
- 受光照的 3D 模型不再出现闪点和生硬高光，光晕会被前方模型正确遮挡，头部也能正确跟随鼠标转动
- 与屏幕混合的图层不再消失或上下颠倒，与壁纸选项或脚本关联的图层也会在该显示时正常显示
- 在“下载”列表中暂停、继续或完成下载时状态会立即更新，简体中文下的下载进度也会显示百分号
- 搜索设置时，已展开部分的内容不再在标题隐藏后仍然显示

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.4.1...v1.5.5

## 1.4.1 — 2026-10-14

### English

Native Metal becomes the default scene renderer, live property previews and wallpaper positioning arrive, and many scene, video, experimental lock screen and Workshop download problems are fixed

#### Breaking changes

- Scene wallpapers now play on the Native Metal renderer by default, switched once on first launch; choose Compatibility in Performance settings to keep the previous renderer

#### New

- The Wallpaper Preview window now follows property edits as you make them, including sliders and colors while you drag, without reloading or touching your desktop
- An optional setting, off by default, shows a scene wallpaper's property edits on your desktop as you make them, before you apply changes
- Scene and video wallpapers can now be moved on each display with Horizontal position and Vertical position sliders in the inspector, following the slider live
- In Settings > Performance > Playback, Low Power Mode, heat and low battery can now switch wallpapers to reduced quality instead of pausing or stopping them
- A new When the battery is low rule, off by default, pauses or stops wallpapers on battery at 10%, 20% or 30% charge
- An optional Playback switch, off by default, keeps playing only the display your pointer is on and pauses the others
- Mute Wallpapers silences every wallpaper at once from the menu bar, Settings, links, Shortcuts or a shortcut key, without changing saved volumes
- Random Wallpaper picks a different wallpaper for a display from all or only favorites, from the menu bar, links, Shortcuts or a shortcut key
- With two or more displays, the menu bar menu has a submenu for each display with Previous, Next, Recently used and Remove from Display
- Apply to all displays sets a wallpaper on every display in one step from the inspector, a link or Shortcuts
- Workshop wallpapers in Discover can now be downloaded and applied to the target display in one step
- Pasting a Workshop item link or id into the Discover search box now shows that item directly instead of searching for the text
- Discover has a new Recently updated sort that lists wallpapers by when they last changed
- Playlists can now change wallpaper each time the Mac is unlocked
- A new switch in Settings > General lets you stop WallpaperMachine from changing the macOS desktop picture, so Mission Control keeps your own picture
- Installed Workshop wallpapers can be reinstalled from the Workshop, keeping your options and the current copy until the new download completes
- Wallpaper properties have a Restore all defaults link that resets every setting to the artist's values in one click
- The inspector can check an installed video for baked-in black bars and set the scale factor that crops them in Fill mode
- Import finds projects in Wallpaper Engine and Steam library folders, accepts a project's own files, recognizes renamed Workshop projects and can replace changed ones
- Wallpaper settings now show the wallpaper's own translated names, and built-in Wallpaper Engine identifiers appear as readable words
- Workshop downloads now show the time left, and the menu bar menu shows how many downloads are running and their progress
- A wallpaper that crashed the app twice while loading is held back at launch, and a banner names it with a Try again button
- A scene that stopped after a rendering failure has a Retry button in the live diagnostics of Performance settings
- On a MacBook, the inspector's energy rating also shows about how much of a full battery charge a wallpaper uses per hour
- An optional switch, off by default, lets Safari's Web Inspector debug web wallpapers
- The diagnostics report now includes macOS resource and hang reports, the wallpaper load history and memory use, and the log explains why wallpapers changed

#### Improved

- Switching to a scene, web page or video on the optional native video playback now keeps the previous picture until the new one appears, instead of flashing black
- Native Metal now draws wallpapers with scene lights, motion trails, fluid and ripple effects and perspective effects instead of handing them to Compatibility
- Customizable scene wallpapers no longer hold memory for layers their settings hide, and Native Metal needs less image memory for heavy wallpapers
- Web wallpapers now honor the frame-rate limit and Internal render scale, and can follow a fast display's full refresh rate when you choose it
- Reapply wallpaper now restarts the wallpaper on the display, so a frozen or blank wallpaper can be revived without choosing another
- Installed tiles show still covers and animate only the preview under the pointer, so a large library no longer keeps the panel busy
- Installed keeps its search, sort, filters and scroll position when you close and reopen the control panel
- The inspector now shows Displays and Collections before a wallpaper's properties, so long property lists no longer push them out of reach
- Property groups now appear as section headings, making long property lists easier to scan
- The Wallpaper Preview window now shows the wallpaper in the shape of the display it previews for
- When launched at login, WallpaperMachine now waits in the menu bar instead of opening the control panel
- Discover keeps listing wallpapers when Steam changes its Workshop page, with a note that the list may be incomplete
- Importing a project identical to one already installed now skips it instead of copying it again
- Backups no longer include the saved Steam sign-in, partial downloads or thumbnail caches, while your library is still backed up
- The update available alert now waits until wallpapers are showing again instead of appearing over full-screen apps or the locked screen

#### Fixed

- Many Workshop effects that were silently missing now appear, including water caustics, sine wave, pixelate, audio bars, color grading, halftone, procedural noise and progress bars
- Image layer colors chosen by a preset or your settings, and effects your settings switch on or off, now take effect
- Wallpapers that change with the time of day now show the right picture instead of a clock on a black screen
- Scene wallpapers whose scripts check the device, create layers from a model or rebuild their layers now run those scripts, so missing bars and elements appear
- Text, clock, scan-line, wave and compose layer effects that read other layers or themselves now show instead of being blank or missing
- A scene that stops after a rendering error, or after the Mac wakes, now restarts by itself instead of staying frozen
- On Native Metal, 3D models no longer show hidden faces, parallax follows the cursor at the right speed and depth matches Compatibility
- Clearing the shader cache while a wallpaper loaded on Native Metal no longer crashes the app
- A scene wallpaper that fails to load no longer leaves the display black, and the previous wallpaper stays
- Trails and echo effects no longer freeze partway with Update only when the scene changes turned on
- Playlists no longer refill a display you cleared, replace a wallpaper you just chose, or forget their shuffle round after a relaunch
- With optional native video playback, Fit, Original size and the scale factor now work, and portrait clips show upright in Mission Control
- With optional native video playback, a clip that freezes after wake or never shows a picture is repaired or handed to Compatibility instead of staying black
- With optional native video playback, a sleeping disk no longer holds up other displays and switching quickly no longer flashes the wallpapers in between
- The experimental animated lock screen no longer goes black or loses its wallpaper because of a stale renderer or unanswered system requests
- Turning on the experimental animated lock screen now explains a switched-off renderer and ends leftover renderers instead of timing out
- The experimental animated lock screen no longer stays frozen after a missed wake, and one sleeping display no longer pauses another
- On macOS 27, Mission Control shows the wallpaper picture again, and quitting is no longer blocked by a desktop picture macOS holds on to
- Quitting, logging out, restarting and shutting down no longer hang while the desktop picture is restored, and a failed restore is explained
- Stopping the app from Terminal now restores the desktop picture first, and an import file picker closing early no longer ends the app
- Workshop downloads retry a dropped connection, restart after the Mac wakes and check free space first instead of stalling or blaming your purchase
- Download progress no longer jumps backwards, and a preset whose base wallpaper failed to download now says so clearly
- Audio-reactive wallpapers recover after you switch the output device, such as connecting headphones
- A display that briefly drops out or reports no size while connecting no longer reloads wallpapers or makes applying fail on other displays
- Plugging in or unplugging the charger while the Mac sleeps is now noticed on wake, so battery settings apply correctly
- Opening a second copy of WallpaperMachine now brings the running one forward instead of sharing the library with it
- The control panel and its windows open on the current Space, and a minimized panel comes back when you open it
- Launch at login now explains when WallpaperMachine must be allowed in Login Items and offers a button to open them
- Wallpaper settings that depend on other options now show and hide correctly for more of Wallpaper Engine's rules
- Web wallpapers that load files inside a frame no longer stall, and audio visualizers no longer freeze mid-decay when music stops
- Paused web wallpapers are now actually suspended, even when the page ignores the pause
- Web wallpapers now receive only changed properties after the first update, so pages no longer redo setup on every edit
- On a MacBook with macOS 27, Energy use in Performance settings shows the battery share per hour again

### 简体中文

Native Metal 成为默认场景渲染器，新增实时属性预览和壁纸位置调整，并修复了大量场景、视频、实验性锁定屏幕和 Workshop 下载问题

#### 不兼容变更

- 场景壁纸现在默认使用 Native Metal 渲染器，首次启动时会自动切换一次；如需继续使用原渲染器，请在性能设置中选择兼容渲染器

#### 新增

- 壁纸预览窗口现在会随你编辑属性实时更新，拖动滑块和颜色时也会跟随，且不会重新载入或影响桌面
- 新增可选设置（默认关闭），可在应用更改之前就把场景壁纸的属性编辑实时显示在桌面上
- 现在可以在检查器中用水平位置和垂直位置滑块调整场景和视频壁纸在每台显示器上的位置，拖动时实时跟随
- 在 设置 > 性能 > 播放 中，低电量模式、Mac 过热和电池电量低时现在可以选择降低画质，而不是暂停或停止壁纸
- 新增电池电量低规则（默认关闭），可在电池供电且电量降至 10%、20% 或 30% 时暂停或停止壁纸
- 播放中新增可选开关（默认关闭），只让指针所在的显示器继续播放，其他显示器暂停
- 静音壁纸功能可从菜单栏、设置、链接、快捷指令或快捷键一次静音所有壁纸，且不改变已保存的音量
- 随机壁纸可从全部壁纸或仅收藏中为显示器换一张不同的壁纸，可通过菜单栏、链接、快捷指令或快捷键使用
- 连接两台或更多显示器时，菜单栏菜单为每台显示器提供子菜单，包含上一张、下一张、最近使用和从显示器移除
- 应用到所有显示器可通过检查器、链接或快捷指令一步将壁纸应用到每台显示器
- 发现中的 Workshop 壁纸现在可以一步完成下载并应用到目标显示器
- 在发现的搜索框中粘贴 Workshop 项目链接或编号，现在会直接显示该项目，而不是按文字搜索
- 发现新增最近更新排序，按壁纸最后更新时间列出
- 播放列表现在可以在每次解锁 Mac 时更换壁纸
- 设置 > 通用 中新增开关，可让 WallpaperMachine 不再更改 macOS 桌面图片，使调度中心保留你自己的图片
- 已安装的 Workshop 壁纸可以从 Workshop 重新安装，保留你的选项，并在新下载完成前保留当前副本
- 壁纸属性新增恢复全部默认值链接，一键将所有设置恢复为作者设定的值
- 检查器可以检查已安装视频中是否有内嵌黑边，并设置在填充模式下裁掉黑边的缩放比例
- 导入现在能在 Wallpaper Engine 和 Steam 资料库文件夹中找到项目，接受项目自身的文件，识别改名的 Workshop 项目，并可替换已更改的项目
- 壁纸设置现在显示壁纸自带的翻译名称，Wallpaper Engine 内置标识符也会显示为可读的文字
- Workshop 下载现在会显示剩余时间，菜单栏菜单也会显示正在进行的下载数量和进度
- 加载时两次导致应用崩溃的壁纸会在启动时暂缓载入，并有横幅指出该壁纸并提供重试按钮
- 因渲染失败而停止的场景会在性能设置的实时诊断中提供重试按钮
- 在 MacBook 上，检查器的能耗评级还会显示壁纸每小时大约消耗多少电池电量
- 新增可选开关（默认关闭），允许用 Safari 的 Web 检查器调试网页壁纸
- 诊断报告现在包含 macOS 资源和无响应报告、壁纸载入记录和内存占用，日志也会说明壁纸为何更换

#### 改进

- 切换到场景、网页或可选原生视频播放中的视频时，现在会保留上一张画面直到新壁纸出现，不再黑屏闪烁
- Native Metal 现在可以绘制带场景光照、运动拖尾、流体和涟漪效果以及透视效果的壁纸，不再交给兼容渲染器
- 可自定义的场景壁纸不再为设置隐藏的图层占用内存，Native Metal 绘制复杂壁纸所需的图像内存也更少
- 网页壁纸现在遵循帧率上限和内部渲染比例，并可在你选择时跟随高刷新率显示器的完整刷新率
- 重新应用壁纸现在会在显示器上重启该壁纸，无需先选择其他壁纸即可恢复卡住或空白的壁纸
- 已安装中的缩略图显示静态封面，只播放指针所在的预览，大型壁纸库不再让面板一直忙碌
- 关闭并重新打开控制面板时，已安装会保留搜索、排序、筛选和滚动位置
- 检查器现在把显示器和收藏集放在壁纸属性之前，较长的属性列表不再把它们挤到远处
- 属性分组现在显示为分节标题，让较长的属性列表更易浏览
- 壁纸预览窗口现在按所预览显示器的比例显示壁纸
- 登录时启动后，WallpaperMachine 现在会停留在菜单栏，而不会自动打开控制面板
- Steam 更改 Workshop 页面时，发现仍会列出壁纸，并提示列表可能不完整
- 导入与已安装项目完全相同的内容时，现在会跳过而不再重复复制
- 备份不再包含已保存的 Steam 登录信息、未完成的下载和缩略图缓存，壁纸库仍会照常备份
- 有可用更新的提醒现在会等到壁纸重新显示时再出现，不再弹在全屏应用或锁定屏幕上方

#### 修复

- 许多此前被悄悄略过的 Workshop 效果现在会显示，包括水面焦散、正弦波、像素化、音频条、调色、半色调、程序噪声和进度条
- 由预设或你的设置选择的图层颜色，以及设置中开关的效果，现在都会生效
- 随一天时间变化的壁纸现在会显示对应画面，不再只在黑屏上显示时钟
- 脚本会检查设备、从模型创建图层或重建图层的场景壁纸，现在能正常运行这些脚本，缺失的音频条和元素会显示出来
- 读取其他图层或自身的文字、时钟、扫描线、波形和组合图层效果现在会正常显示，不再空白或缺失
- 因渲染错误或 Mac 唤醒后停止的场景现在会自动重新启动，而不是一直卡住
- 在 Native Metal 上，3D 模型不再显示应隐藏的面，视差以正确速度跟随指针，深度表现与兼容渲染器一致
- 在 Native Metal 载入壁纸时清除着色器缓存不再导致应用崩溃
- 场景壁纸载入失败时不再让显示器变黑，会保留之前的壁纸
- 开启仅在场景变化时更新后，拖尾和回声效果不再中途冻结
- 播放列表不再为你清空的显示器重新放入壁纸，不再替换你刚选择的壁纸，重启后也不会忘记随机轮次
- 使用可选的原生视频播放时，适应、原始大小和缩放比例现在都能生效，竖拍视频在调度中心中也会正立显示
- 使用可选的原生视频播放时，唤醒后冻结或始终不出画面的视频会被修复或交给兼容模式，不再一直黑屏
- 使用可选的原生视频播放时，休眠的磁盘不再拖慢其他显示器，快速切换时也不再闪现中间的壁纸
- 实验性的动态锁定屏幕不再因旧的渲染进程或未响应的系统请求而变黑或丢失壁纸
- 开启实验性的动态锁定屏幕时，现在会说明渲染器已被关闭并结束残留的渲染进程，不再等待超时
- 实验性的动态锁定屏幕在漏掉唤醒通知后不再冻结，一台显示器休眠也不再暂停另一台
- 在 macOS 27 上，调度中心重新显示壁纸画面，退出也不再被 macOS 保留的桌面图片阻止
- 退出、注销、重启和关机时不再因恢复桌面图片而卡住，恢复失败时也会给出说明
- 从终端停止应用时现在会先恢复桌面图片，导入文件选择器提前关闭也不再导致应用退出
- Workshop 下载会在连接中断时重试、在 Mac 唤醒后重新开始，并预先检查可用空间，不再卡住或误报购买问题
- 下载进度不再倒退，预设的基础壁纸下载失败时现在也会明确说明
- 切换输出设备后（例如连接耳机），音频响应壁纸会恢复正常
- 短暂断开或连接时未报告尺寸的显示器，不再导致壁纸重新载入或在其他显示器上应用失败
- 在 Mac 睡眠时插拔充电器，现在会在唤醒时被识别，电池相关设置会正确生效
- 打开第二个 WallpaperMachine 副本时，现在会把正在运行的副本调到前台，而不是与其共用壁纸库
- 控制面板及其窗口会在当前空间中打开，最小化的面板在你打开时也会恢复
- 登录时启动现在会说明何时需要在登录项中允许 WallpaperMachine，并提供打开登录项的按钮
- 依赖其他选项的壁纸设置现在能按更多 Wallpaper Engine 规则正确显示和隐藏
- 在框架内载入文件的网页壁纸不再卡住，音乐停止时音频可视化也不再在衰减中途冻结
- 暂停的网页壁纸现在会被真正挂起，即使网页本身忽略暂停请求
- 网页壁纸在首次更新后只接收已更改的属性，网页不再在每次编辑时重复初始化
- 在运行 macOS 27 的 MacBook 上，性能设置中的能耗再次显示每小时电池占比

**Full changelog**: https://github.com/TheNightlyGod/WallpaperMachine-intel/compare/v1.3.3...v1.4.1

## 1.4.0 — 2026-10-13

### English

WallpaperMachine 1.4.0 makes Native Metal the default scene renderer, lets you see property edits and position wallpapers live, and adds menu bar, playlist and download controls

#### Breaking changes

- Scene wallpapers now play on the Native Metal renderer by default, and you can choose Compatibility again in Settings > Performance

#### New

- An optional setting, off by default, shows a scene wallpaper's property edits on the desktop as you make them, before you apply them
- The Wallpaper Preview window now follows property edits for scene and web wallpapers, including sliders and colors while you drag them
- New Horizontal position and Vertical position sliders set where a scene or video wallpaper sits on each display, and the wallpaper follows while you drag
- Low Power Mode, a hot Mac and a low battery can now reduce wallpaper quality instead of pausing, set in Settings > Performance > Playback
- A new When the battery is low rule, off by default, pauses or stops wallpapers at 10%, 20% or 30% charge
- An optional Playback switch, off by default, plays wallpapers only on the display your pointer is on and pauses the others
- Mute every wallpaper at once from the menu bar, Settings, a link, Shortcuts or a shortcut key without changing any saved volume
- A new Random Wallpaper command picks a different wallpaper for a display from all wallpapers or your favorites
- With two or more displays, the menu bar menu has a submenu for each display with Previous, Next, Recently used and Remove from Display
- Apply a wallpaper to every display in one step from its inspector, a link or Shortcuts
- Playlists can now change the wallpaper each time the Mac is unlocked
- The menu bar menu shows running Workshop downloads with their overall progress and opens Discover when chosen
- Download a Workshop wallpaper and apply it to your display in one step
- Paste a Workshop link or item id into the Discover search box to open that item directly
- Discover can sort wallpapers by when they were last updated
- Reinstall an installed Workshop wallpaper from the Workshop while keeping your options and collections and without deleting the current copy first
- Import finds projects in Wallpaper Engine and Steam folders, recognizes renamed Workshop projects and can replace an installed project that changed
- A new switch in Settings > General stops WallpaperMachine from changing the macOS desktop picture
- Check an installed video for baked-in black bars and set the scale factor that crops them with one click
- Restore all defaults puts every property of a wallpaper back to the values its artist chose in one click
- Reapply wallpaper now restarts a frozen or blank wallpaper on its display
- A scene that stopped after a rendering failure offers a Retry button in Settings > Performance
- On a MacBook, a wallpaper's energy rating in the inspector also shows the share of a full battery charge it uses per hour
- An optional switch, off by default, lets Safari's Web Inspector debug web wallpapers

#### Improved

- Native Metal now draws wallpapers with scene lights, motion trails, fluid and ripple effects and perspective effects instead of switching them to Compatibility
- Customizable scene wallpapers no longer hold memory for layers their settings hide, cutting one wallpaper's memory use from about 12.7 GB to 1.6 GB
- Switching wallpapers keeps the previous picture on screen until the new one is ready instead of showing a black screen
- Web wallpapers now follow the render scale and frame-rate limit, and can draw at a fast display's full refresh rate when you choose it
- Workshop downloads retry a dropped connection up to three times and restart on their own when the connection stalls after the Mac wakes
- Workshop downloads show the estimated time left, and their progress no longer jumps backwards
- Discover keeps listing wallpapers when Steam changes its Workshop page, with a note that the list may be incomplete
- Long property lists are easier to scan, with groups shown as section headings and Displays and Collections placed above the properties
- Wallpaper settings show the wallpaper's own translations and readable names instead of internal identifiers
- More wallpaper settings now appear and hide along with the options they depend on
- Installed keeps its search, filters, sort and scroll position when you close and reopen the control panel
- Installed shows still covers and plays a preview only for the tile under the pointer, so large libraries stay responsive
- The Wallpaper Preview window shows wallpapers in the proportions of the display they are for
- When launched at login, the app stays in the menu bar instead of opening the control panel
- The update alert now waits until wallpapers are showing again instead of appearing over full-screen apps or the locked screen
- Time Machine no longer backs up your Steam sign-in, partial downloads or thumbnail caches

#### Fixed

- Many Workshop effects that were silently missing now draw, including water caustics, sine wave, pixelate, audio bars, color grading, halftone and procedural noise
- Wallpapers that change with the time of day no longer show only a clock on a black screen
- Presets such as Black and white and your color settings now change the colors of image layers
- Effects that a wallpaper's settings switch on or off now follow the option you choose
- Scene wallpapers whose scripts check the device, rebuild their layers or build audio visualizer bars from models now work
- Scrolling text strips, clock outlines, scan lines and other layers that show another layer or themselves now appear instead of staying empty or black
- Trail and echo effects no longer freeze partway when Update only when the scene changes is on
- A scene wallpaper that stops after a rendering error or after the Mac wakes now restarts by itself
- The app no longer crashes at every launch because of a wallpaper that crashes while loading; the panel names it and offers Try again
- Native Metal no longer draws hidden faces of 3D models, moves parallax too fast or crashes the app when the shader cache is cleared
- Native video now honors Fit, Original size and the scale factor, and Mission Control shows portrait clips upright
- Native video wallpapers that show no picture, stall after a wake or wait on a slow disk now recover or switch to Compatibility instead of staying black
- Switching quickly between native video wallpapers no longer flashes the ones in between
- The experimental animated Lock screen and screen saver no longer freeze after a wake, lose their wallpaper or stay black after a reinstall
- Turning on the experimental animated Lock screen no longer waits about 30 seconds when its renderer is switched off or left over from another copy
- Mission Control shows the wallpaper again on macOS 27, and quitting is no longer blocked while macOS restores the desktop
- Quitting no longer hangs or holds up logout, restart and shutdown, and stopping the app from Terminal restores your desktop picture
- Playlists remember their shuffle round across relaunches, no longer refill a display you cleared and never replace a wallpaper you just picked
- A failed switch to a scene wallpaper no longer leaves the display black
- A display that briefly disconnects or reports no size no longer reloads wallpapers or makes applying fail on other displays
- A paused web wallpaper now stops completely, so its animations and videos no longer keep running behind it
- Web wallpapers that load files inside a frame no longer stall, and their audio visualizers settle when the music stops
- Audio-reactive wallpapers recover after you switch the audio output device
- Plugging in or unplugging the charger while the Mac sleeps is now noticed when it wakes
- A Workshop download that cannot fit on the disk stops at once and says how much space it needs instead of stalling
- When only a preset's base wallpaper fails to download, the error now says so
- The control panel and other windows open on your current Space, and a minimized panel comes back when you open it
- Opening a second copy of WallpaperMachine no longer runs it beside the first on the same library
- Launch at login now explains when WallpaperMachine needs approval in Login Items and opens that setting for you
- On macOS 27, Settings > Performance shows how much of a full battery charge the app uses per hour again
- The app no longer quits suddenly when a helper process, such as the import file picker, ends first

### 简体中文

WallpaperMachine 1.4.0 将 Native Metal 设为默认场景渲染器，支持实时查看属性编辑和调整壁纸位置，并新增菜单栏、播放列表和下载相关控制

#### 不兼容变更

- 场景壁纸现默认使用 Native Metal 渲染器播放，你可以在“设置 > 性能”中重新选择兼容渲染器

#### 新增

- 新增可选设置（默认关闭），在你编辑场景壁纸属性时，桌面会在应用前即时显示改动
- 壁纸预览窗口现会跟随场景和网页壁纸的属性编辑更新，拖动滑块和颜色时也会同步显示
- 新增水平位置和垂直位置滑块，可设置场景或视频壁纸在每台显示器上的位置，拖动时壁纸实时跟随
- 低电量模式、Mac 过热和电池电量低时，现可选择降低壁纸画质而不是暂停，可在“设置 > 性能 > 播放”中设置
- 新增“电池电量低时”规则（默认关闭），可在电量降至 10%、20% 或 30% 时暂停或停止壁纸
- 播放设置新增可选开关（默认关闭），仅在指针所在的显示器上播放壁纸，并暂停其他显示器
- 可通过菜单栏、设置、链接、快捷指令或快捷键一次将所有壁纸静音，不会更改任何已保存的音量
- 新增“随机壁纸”命令，可从全部壁纸或收藏中为显示器随机换上另一张壁纸
- 连接两台或以上显示器时，菜单栏菜单为每台显示器提供子菜单，包含上一张、下一张、最近使用和从显示器移除
- 可在检查器、链接或快捷指令中一步将壁纸应用到所有显示器
- 播放列表现在可以在每次解锁 Mac 时更换壁纸
- 菜单栏菜单会显示正在进行的 Workshop 下载及总体进度，选择后会打开“发现”
- 可一步下载 Workshop 壁纸并将其应用到显示器
- 在“发现”的搜索框中粘贴 Workshop 链接或物品 ID，即可直接打开该物品
- “发现”现在可以按最近更新时间排序壁纸
- 可从 Workshop 重新安装已安装的壁纸，保留你的选项和收藏，且不会先删除现有副本
- 导入现可在 Wallpaper Engine 和 Steam 文件夹中查找项目，识别改名的 Workshop 项目，并可替换已更改的已安装项目
- “设置 > 通用”新增开关，可让 WallpaperMachine 不再更改 macOS 桌面图片
- 可检查已安装视频是否自带黑边，并一键设置裁去黑边所需的缩放系数
- “全部恢复默认”可一键将壁纸的所有属性恢复为作者设定的值
- “重新应用壁纸”现在会在显示器上重启卡住或空白的壁纸
- 因渲染故障而停止的场景会在“设置 > 性能”中提供重试按钮
- 在 MacBook 上，检查器中壁纸的能耗评级还会显示其每小时消耗的满电量比例
- 新增可选开关（默认关闭），允许使用 Safari 网页检查器调试网页壁纸

#### 改进

- Native Metal 现可直接绘制带场景光照、运动拖尾、流体与波纹效果及透视效果的壁纸，不再将其切换到兼容渲染器
- 可自定义的场景壁纸不再为设置中隐藏的图层占用内存，其中一款壁纸的内存占用从约 12.7 GB 降至 1.6 GB
- 切换壁纸时会保留上一张画面，直到新壁纸准备就绪，不再显示黑屏
- 网页壁纸现在遵循渲染比例和帧率上限，并可在你选择时以高刷新率显示器的完整刷新率绘制
- Workshop 下载在连接中断时最多自动重试三次，Mac 唤醒后连接停滞时也会自行重新开始
- Workshop 下载现在会显示预计剩余时间，进度也不再倒退
- Steam 更改其 Workshop 页面后，“发现”仍会列出壁纸，并提示列表可能不完整
- 较长的属性列表更易浏览，分组显示为小标题，显示器和收藏部分也移到了属性上方
- 壁纸设置现在显示壁纸自带的翻译和易读的名称，而不是内部标识符
- 更多壁纸设置现会随其依赖的选项一起显示或隐藏
- 关闭并重新打开控制面板后，“已安装”会保留搜索、筛选、排序和滚动位置
- “已安装”显示静态封面，仅播放指针所在卡片的预览，大型壁纸库也能保持流畅
- 壁纸预览窗口会按目标显示器的比例显示壁纸
- 登录时启动的应用会停留在菜单栏中，不再自动打开控制面板
- 更新提示现在会等到壁纸重新显示后再出现，不再弹出在全屏应用或锁定的屏幕上
- Time Machine 不再备份你的 Steam 登录信息、未完成的下载和缩略图缓存

#### 修复

- 许多此前悄然缺失的 Workshop 效果现可正常绘制，包括水面焦散、正弦波、像素化、音频条、调色、半色调和程序噪点
- 随时间变化的壁纸不再只在黑屏上显示一个时钟
- “黑白”等预设和你的颜色设置现在能正确改变图像图层的颜色
- 由壁纸设置开启或关闭的效果现在会按你选择的选项生效
- 脚本会检测设备、重建图层或用模型生成音频可视化条的场景壁纸现在可以正常运行
- 滚动文字条、时钟描边、扫描线等显示其他图层或自身的图层现在能正常出现，不再空白或全黑
- 开启“仅在场景变化时更新”后，拖尾和回声效果不再中途冻结
- 因渲染错误或 Mac 唤醒后停止的场景壁纸现在会自行重新启动
- 应用不再因某个加载时崩溃的壁纸而每次启动都崩溃；面板会显示该壁纸并提供重试按钮
- Native Metal 不再绘制 3D 模型被隐藏的面、不再让视差移动过快，清除着色器缓存时也不再导致应用崩溃
- 原生视频现在会遵循适合、原始大小和缩放系数设置，调度中心也会正向显示竖拍视频
- 不显示画面、唤醒后停滞或等待慢速磁盘的原生视频壁纸现会自行恢复或切换到兼容渲染器，不再保持黑屏
- 快速切换原生视频壁纸时不再闪现中间的壁纸
- 实验性的动态锁定屏幕和屏幕保护程序不再在唤醒后冻结、丢失壁纸或在重新安装后保持黑屏
- 当渲染器被关闭或残留自其他副本时，开启实验性的动态锁定屏幕不再需要等待约 30 秒
- 在 macOS 27 上调度中心重新显示壁纸，macOS 恢复桌面时退出也不再被阻止
- 退出不再卡住，也不再拖延注销、重启和关机，从终端停止应用时也会恢复你的桌面图片
- 播放列表在重新启动后会记住随机轮次，不再重新填充你已清空的显示器，也不会替换你刚选的壁纸
- 切换场景壁纸失败后，显示器不再保持黑屏
- 短暂断开或未报告尺寸的显示器不再导致壁纸重新加载，也不再让其他显示器应用壁纸失败
- 暂停的网页壁纸现在会被完全停止，其动画和视频不再在后台继续运行
- 在框架内加载文件的网页壁纸不再卡住，音乐停止后其音频可视化也会正常回落
- 切换音频输出设备后，音频响应壁纸会恢复正常
- Mac 睡眠期间接上或拔下充电器后，唤醒时现在能识别这一变化
- 磁盘空间不足的 Workshop 下载会立即停止并说明所需空间，不再卡住
- 仅预设所依赖的基础壁纸下载失败时，错误信息现在会明确说明
- 控制面板和其他窗口会在当前空间打开，已最小化的面板在再次打开时会恢复显示
- 再次打开 WallpaperMachine 时，不会再有第二个副本与第一个副本同时使用同一壁纸库
- 登录时启动现在会说明 WallpaperMachine 需要在登录项中获得允许，并可直接打开该设置
- 在 macOS 27 上，“设置 > 性能”重新显示应用每小时消耗的满电量比例
- 导入文件选择器等辅助进程先行结束时，应用不再突然退出

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.3.3...v1.4.0

## 1.3.3 — 2026-10-11

### English

This release lets playlists rotate at any interval you choose and makes many scene wallpapers, especially audio visualizers, look and move as they do in Wallpaper Engine

#### New

- Playlists can now rotate at any whole number of minutes from 1 to 10,080 by choosing Custom under How often

#### Improved

- On Macs with an XDR display, changes in HDR brightness no longer make the app refresh every display and redraw the control panel over and over
- Dragging property sliders and other control panel updates respond more quickly
- The app no longer stalls for hundreds of milliseconds during bursts of screen changes
- With the experimental animated lock screen or the screen saver on, the app no longer rereads macOS wallpaper settings and writes to disk when nothing has changed
- The Energy use readout in Settings > Performance now notes that figures shown right after applying a wallpaper include loading it
- Scene assets that Steam installs or removes while the app is running are now picked up when you return to the control panel

#### Fixed

- Audio-reactive wallpapers now show thin, separate bars of varying length that move with the music, as in Wallpaper Engine
- Audio visualizers built from imported Workshop assets show their bars again instead of nothing
- Blended puppet shadows now darken what is behind them instead of showing a shrunken copy of the wallpaper with grey blocks
- Motion blur trails no longer show faint, misplaced copies of other layers
- Rotated layers aligned to an edge now turn about that edge and stay where their authors placed them
- Web wallpapers no longer freeze briefly when you move the pointer while Show Desktop reveals them
- The Energy use readout no longer shows videos played with optional native video playback as almost free and no longer rates them

### 简体中文

此版本允许播放列表按你设定的任意间隔轮换，并让许多场景壁纸（尤其是音频可视化壁纸）的外观和动态与 Wallpaper Engine 中一致

#### 新增

- 在播放列表的轮换频率中选择“自定义”，即可按 1 至 10,080 之间的任意整数分钟轮换壁纸

#### 改进

- 在配备 XDR 显示器的 Mac 上，HDR 亮度变化不再导致应用反复刷新所有显示器并重绘控制面板
- 拖动属性滑块及控制面板的其他更新响应更快
- 屏幕连续发生变化时，应用不再卡顿数百毫秒
- 开启实验性的动态锁定屏幕或屏幕保护程序时，应用不再在没有变化的情况下重复读取 macOS 壁纸设置并写入磁盘
- 设置 > 性能中的能耗读数现会注明，刚应用壁纸后的数值包含了加载壁纸的消耗
- 应用运行期间由 Steam 安装或移除的场景资源，现会在你返回控制面板时被识别

#### 修复

- 音频响应壁纸现会像在 Wallpaper Engine 中一样，显示随音乐跳动、长短不一且彼此分开的细条
- 使用导入的 Workshop 资源制作的音频可视化效果重新显示音频条，不再一片空白
- 混合模式的人偶阴影现会正常压暗其后方内容，不再显示缩小的壁纸副本和灰色色块
- 动态模糊拖影不再出现其他图层的模糊错位副本
- 对齐到边缘的图层旋转时现会以该边缘为轴，并保持在作者设定的位置
- 通过“显示桌面”露出网页壁纸时移动指针，网页壁纸不再短暂卡住
- 能耗读数不再将使用可选原生视频播放的视频显示为几乎没有消耗，也不再对其评级

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.3.2...v1.3.3

## 1.3.2 — 2026-10-08

### English

This release adds playlists, per-display wallpaper history, automatic wallpaper choices and saved multi-display layouts, and keeps the Mission Control picture closer to your actual wallpaper

#### New

- Create reorderable playlists that automatically skip wallpapers that fail to play, within a set limit
- Each display keeps a history of recent wallpapers, and Previous takes you back to the one before
- Choose wallpapers automatically by weekday, solar times, light or dark appearance, and Focus
- Save layouts for multiple displays, copy or swap them between displays, and restore a saved layout
- Use Shortcuts to control playlists, property presets and display layouts
- Scene, Video and Web wallpapers each get their own muted preview
- Experimental: choose a different wallpaper for each desktop Space
- Settings › General adds an option, off by default, to update the Mission Control picture every 5 minutes for wallpapers that change over time

#### Improved

- Mission Control shows a more current wallpaper picture, retaken shortly after a wallpaper starts, changes or resumes, and after Space changes and wake
- Wallpapers you pick yourself now take priority over pending automatic changes
- The app now explains which options cannot be used with the experimental animated lock screen

#### Fixed

- Web wallpapers no longer pause their animation during desktop transitions
- With the animated lock screen on, Mission Control no longer shows a black picture for wallpapers that fade in
- The file picker for importing wallpapers no longer becomes unresponsive while waiting for you to choose or cancel

### 简体中文

此版本新增播放列表、按显示器记录的壁纸历史、自动选择壁纸和多显示器布局保存，并让调度中心中的画面更贴近实际壁纸

#### 新增

- 可创建能调整顺序的播放列表，并在一定限度内自动跳过无法播放的壁纸
- 每个显示器都会保留最近使用的壁纸记录，可通过“上一个”返回之前的壁纸
- 可按星期、太阳时段、浅色或深色外观以及专注模式自动选择壁纸
- 可保存多显示器布局，在显示器之间复制或交换，并恢复已保存的布局
- 可通过快捷指令控制播放列表、属性预设和显示器布局
- 场景、视频和网页壁纸各自拥有独立的静音预览
- 实验性功能：可为每个桌面空间选择不同的壁纸
- 设置 › 通用新增一个默认关闭的选项，可每 5 分钟更新一次调度中心中的壁纸画面，适合随时间变化的壁纸

#### 改进

- 调度中心中的壁纸画面更及时，会在壁纸启动、切换或恢复后不久以及切换空间和唤醒后重新截取
- 你手动选择的壁纸现在会优先于待执行的自动切换
- 应用现在会说明哪些选项无法与实验性的动态锁定屏幕同时使用

#### 修复

- 网页壁纸在桌面切换过渡期间不再出现动画暂停
- 开启动态锁定屏幕时，调度中心不再为淡入显示的壁纸显示黑色画面
- 导入壁纸时的文件选择器在等待选择或取消时不再失去响应

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.6...v1.3.2

## 1.3.1 — 2026-10-08

### English

This release adds reorderable playlists, a Previous button, scheduled wallpaper changes, saved multi-display layouts and Shortcuts actions, and keeps the Mission Control picture closer to what is playing

#### New

- Create playlists you can reorder, and a playlist now skips a limited number of wallpapers that fail to load instead of stopping
- Each display keeps a history of recent wallpapers, and Previous takes you back to the one before
- Wallpapers can change automatically by weekday, sunrise and sunset, light or dark appearance, or the current Focus
- Save wallpaper layouts for multiple displays, restore them later, and copy or swap wallpapers between displays
- Shortcuts can now start playlists and apply property presets and saved layouts
- Preview Scene, Video and Web wallpapers independently, muted, before using them
- Experimental option to choose a different wallpaper for each desktop Space
- Settings › General adds an option, off by default, to update the Mission Control picture every 5 minutes for wallpapers that change over time

#### Improved

- The Mission Control picture is retaken shortly after a wallpaper starts, changes or resumes, and refreshed after switching Spaces or waking the Mac
- Wallpapers you pick yourself now take priority over pending automatic changes
- The app now explains when an option cannot be used with the experimental animated lock screen

#### Fixed

- Web wallpapers no longer pause their animation during desktop transitions such as switching Spaces
- With the experimental animated lock screen on, Mission Control no longer shows a black picture for wallpapers that fade in

### 简体中文

此版本新增可重新排序的播放列表、上一张按钮、定时切换壁纸、多显示器布局保存和快捷指令操作，并让调度中心中的壁纸画面更贴近实际播放内容

#### 新增

- 可以创建能重新排序的播放列表，遇到无法加载的壁纸时会跳过有限数量的壁纸，而不是停止播放
- 每个显示器都会保留最近使用的壁纸记录，可以用上一张返回之前的壁纸
- 壁纸可以按星期、日出日落、浅色或深色外观以及当前专注模式自动切换
- 可以保存多显示器的壁纸布局并在之后恢复，还可以在显示器之间复制或交换壁纸
- 现在可以通过快捷指令启动播放列表、应用属性预设和已保存的布局
- 使用前可以分别静音预览场景、视频和网页壁纸
- 新增实验性选项，可为每个桌面空间选择不同的壁纸
- 设置 › 通用新增默认关闭的选项，可每 5 分钟更新一次调度中心中的壁纸画面，适合随时间变化的壁纸

#### 改进

- 壁纸启动、切换或恢复播放后不久会重新截取调度中心中的画面，切换空间或唤醒 Mac 后也会刷新
- 你手动选择的壁纸现在优先于待执行的自动切换
- 当某个选项无法与实验性的动态锁定屏幕同时使用时，应用现在会给出说明

#### 修复

- 网页壁纸在切换空间等桌面过渡期间不再暂停动画
- 开启实验性的动态锁定屏幕时，调度中心不再为淡入效果的壁纸显示黑色画面

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.6...v1.3.1

## 1.3.0 — 2026-10-08

### English

This release adds playlists, wallpaper history, schedules, multi-display layouts and Shortcuts, keeps the Mission Control picture current and keeps web wallpapers animating during desktop transitions

#### New

- Create playlists you can reorder, and wallpapers that fail to load are skipped so playback keeps going
- Each display keeps a recent wallpaper history, so you can go back to the previous wallpaper
- Switch wallpapers automatically by weekday, sunrise and sunset, light or dark appearance, or Focus
- Save layouts for multiple displays, copy or swap wallpapers between displays, and restore a saved layout
- Use Shortcuts to start playlists, apply property presets and switch layouts
- General settings add an option, off by default, to update the Mission Control picture every 5 minutes for wallpapers that change over time
- Experimental: choose a different wallpaper for each desktop Space
- Scene, video and web wallpapers can each be previewed separately, with sound muted

#### Improved

- Mission Control now shows the wallpaper as it looks a few seconds after it starts, and refreshes the picture when you switch Spaces or wake your Mac
- Wallpapers you choose yourself now take priority over scheduled or automatic changes
- The Mission Control picture is now saved faster and takes about a third of the space
- The app now explains when an option does not work with the experimental animated lock screen

#### Fixed

- Web wallpapers no longer briefly pause their animation during desktop transitions
- With the experimental animated lock screen on, Mission Control no longer shows a black picture for wallpapers that fade in

### 简体中文

本版本新增播放列表、壁纸历史、自动切换条件、多显示器布局和快捷指令，让调度中心画面保持最新，并让网页壁纸在桌面过渡时持续播放动画

#### 新增

- 可创建能重新排序的播放列表，无法加载的壁纸会被跳过，播放可以继续进行
- 每台显示器都会保留最近的壁纸历史，你可以返回上一张壁纸
- 可按星期、日出日落、浅色或深色外观以及专注模式自动切换壁纸
- 可保存多显示器布局，在显示器之间复制或交换壁纸，并恢复已保存的布局
- 可通过快捷指令启动播放列表、应用属性预设和切换布局
- 通用设置新增默认关闭的选项，可每 5 分钟更新一次调度中心画面，适合会随时间变化的壁纸
- 实验性功能：可为每个桌面空间选择不同的壁纸
- 场景、视频和网页壁纸都可以分别预览，预览时静音

#### 改进

- 调度中心现在会显示壁纸启动几秒后的样子，并在切换空间或唤醒 Mac 时刷新画面
- 你手动选择的壁纸现在会优先于计划或自动切换
- 调度中心画面的保存速度更快，占用空间约为原来的三分之一
- 当某个选项与实验性的动态锁定屏幕不兼容时，应用现在会给出说明

#### 修复

- 网页壁纸在桌面过渡期间不再短暂暂停动画
- 开启实验性的动态锁定屏幕后，调度中心不再为淡入的壁纸显示黑色画面

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.6...v1.3.0

## 1.2.6 — 2026-10-07

### English

This release gets Discover working again with Steam's current Workshop pages and makes your subscriptions easier to find. It also fixes many problems with playlists, identical monitors, large downloads and the experimental animated lock screen

#### New

- Discover now opens with Wallpapers, Collections and Your subscriptions tabs, and Your subscriptions shows your sign-in, subscription count and a prominent download button
- Discover shows an Open on Steam button that opens the Steam page listing what is currently on show

#### Improved

- With Questionable or Mature hidden, as by default, Collections pages are now filled to 30 tiles instead of showing only a handful
- Sound-reactive web wallpapers no longer keep the app reading audio while paused, and reading starts again with playback
- Your Steam sign-in is no longer sent along when Steam redirects a request to another address
- Download the ones not in your library is now disabled when there is nothing to download
- The Discover list tabs can now be switched with the arrow, Home and End keys, like the page tabs
- The top tabs no longer all grey out while a page opens, and the Filter button is disabled while its change is saved

#### Fixed

- Discover no longer shows Workshop unavailable for every search after Steam changed its browse page format
- Your subscriptions lists your subscribed wallpapers again when signed in to Steam, instead of reporting an unreadable Workshop page
- Large Workshop downloads no longer fail with SteamCMD timed out while they are still downloading
- Two identical monitors no longer swap wallpapers after macOS renumbers displays, and duplicate display entries in settings are cleaned up on next launch
- Updates without a usable checksum are now refused as unverifiable before downloading, instead of being installed without a check
- Turning on the experimental animated lock screen no longer reports success before it draws, which left it off again after a relaunch
- The experimental animated lock screen and wallpaper screen saver now repair conflicts with other copies of WallpaperMachine automatically
- With only Use wallpaper as screen saver on, the desktop picture in Mission Control and when switching Spaces follows wallpaper changes again
- When switching wallpapers, the old wallpaper's still picture no longer takes the desktop back or stops the new one from showing
- A playlist change that falls due while windows cover a display now happens as soon as the desktop shows again
- Change now and Next Wallpaper now move a playlist along while its display is paused, covered or waiting on a scheduled change
- Links, keyboard shortcuts and Shortcuts no longer report success when a playlist has no other wallpaper to change to or cannot change
- A display that failed to pause or resume its wallpaper and was unplugged meanwhile now pauses or resumes correctly when reconnected
- If the renderer fails to start, opening the control panel from a link, keyboard shortcut or Shortcuts now works at once instead of failing after 15 seconds
- Error alerts from Play/Pause in the menu bar or from files opened at launch no longer stall the app or hang quitting
- Help with emailed codes, shown while Steam waits for a Steam Guard code, now opens Steam's help page
- A quick second change to the same control, such as another slider move or search, is no longer dropped after the first was rejected
- When a Discover list fails to open, the previous list no longer stays on screen, and Try again reloads the list that failed
- Pages hidden entirely by the age rating filters now say so and offer the next page, instead of saying you subscribe to nothing
- Changing the search while a Collections page fills no longer mixes in the old search's collections

### 简体中文

本版本让发现重新适配 Steam 当前的 Workshop 页面，并让你的订阅更容易找到。它还修复了播放列表、相同型号显示器、大型下载和实验性锁定屏幕动画的诸多问题

#### 新增

- 发现现在顶部提供壁纸、合集和你的订阅标签页，你的订阅会显示登录状态、订阅数量和醒目的下载按钮
- 发现新增在 Steam 上打开按钮，可打开当前所示内容对应的 Steam 列表页面

#### 改进

- 在默认隐藏 Questionable 或 Mature 内容时，合集每页现在会填满 30 项，不再只显示寥寥几个
- 响应声音的网页壁纸暂停时，应用不再持续读取音频，恢复播放后再重新开始读取
- 当 Steam 将请求重定向到其他地址时，你的 Steam 登录信息不再随之发送
- 没有可下载的内容时，下载不在壁纸库中的项目按钮现在会被禁用
- 发现中的列表标签页现在可以像页面标签页一样用方向键、Home 和 End 键切换
- 页面打开时顶部标签页不再全部变灰，筛选按钮在其更改保存期间会被禁用

#### 修复

- Steam 更改浏览页面格式后，发现中每次搜索都显示 Workshop 不可用的问题已修复
- 登录 Steam 后，你的订阅会再次列出已订阅的壁纸，不再提示 Workshop 页面无法读取
- 仍在下载中的大型 Workshop 项目不再因 SteamCMD 超时而失败
- macOS 重新编号显示器后，两台相同型号的显示器不再互换壁纸，设置中重复的显示器条目也会在下次启动时清理
- 缺少可用校验和的更新现在会在下载前被视为无法验证而拒绝，不再未经检查就安装
- 开启实验性的锁定屏幕动画时，不再在画面绘制前就报告已启用，从而避免重新启动后又被关闭
- 实验性的锁定屏幕动画和壁纸屏幕保护程序现在会自动修复与其他 WallpaperMachine 副本之间的冲突
- 仅开启将壁纸用作屏幕保护程序时，调度中心和切换空间时显示的桌面图片会再次跟随壁纸变化
- 切换壁纸时，旧壁纸的静态图片不再夺回桌面，也不再阻止新图片显示
- 窗口遮挡显示器期间到期的播放列表切换，现在会在桌面重新露出时立即进行
- 显示器暂停、被遮挡或正在等待计划切换时，立即切换和下一张壁纸现在也会让播放列表前进
- 当播放列表没有其他可切换的壁纸或无法切换时，链接、键盘快捷键和快捷指令不再报告成功
- 暂停或恢复壁纸失败且期间被拔出的显示器，重新连接后会正确暂停或恢复
- 渲染器无法启动时，通过链接、键盘快捷键或快捷指令打开控制面板现在会立即成功，不再等待 15 秒后失败
- 菜单栏中播放/暂停或启动时打开文件产生的错误提示，不再使应用卡住或导致退出时挂起
- 等待 Steam Guard 邮件验证码时显示的邮件验证码帮助，现在会打开 Steam 的帮助页面
- 前一次更改被拒绝后，紧接着对同一控件的更改（例如再次拖动滑块或搜索）不再被丢弃
- 发现中的列表打开失败时，上一个列表不再留在屏幕上，重试会重新加载失败的列表
- 被年龄分级筛选完全隐藏的页面现在会说明情况并提供下一页，不再显示你没有任何订阅
- 在合集页面加载期间更改搜索，不再混入旧搜索的合集

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.5...v1.2.6

## 1.2.5 — 2026-10-05

### English

This update fixes a control panel freeze, stalled wallpaper changes after display changes and an empty Your subscriptions list, along with several wallpaper playback problems

#### Improved

- When Steam returns a Workshop page the app cannot read, it now says so instead of showing an empty list

#### Fixed

- The control panel no longer freezes after a failed redraw when you switch tabs, and instead shows the error in its banner and keeps responding
- After a display is rearranged, changes resolution or wakes from sleep, applying a wallpaper no longer hangs for 90 seconds and wrongly restores the previous one
- Your subscriptions now lists your subscribed wallpapers after signing in to Steam, and Download the ones not in your library finds them too
- Web wallpapers that load local files no longer stay stuck on their loading screen
- Workshop presets that bring their own background pictures or videos now show them instead of a black screen
- With the optional native video playback, video wallpapers keep playing without sound when the Mac's audio output cannot start, instead of switching to Compatibility playback
- WallpaperMachine no longer retries endlessly on desktops whose still wallpaper macOS refuses, and tries again when you switch to them or the Mac wakes
- Day/night switches in Workshop presets now keep their pill shape and appear where the preset places them, without leaving the optional Native Metal renderer

### 简体中文

本次更新修复了控制面板卡死、显示器变化后应用壁纸停滞以及“你的订阅”列表为空的问题，并解决了多项壁纸播放问题

#### 改进

- 当 Steam 返回无法读取的 Workshop 页面时，应用现在会明确提示，而不是显示为空列表

#### 修复

- 切换标签页时若重绘失败，控制面板不再整窗卡死，而是在错误横幅中显示问题并继续响应操作
- 显示器重新排列、更改分辨率或从睡眠中唤醒后，应用壁纸不再卡住 90 秒并错误地恢复为之前的壁纸
- 登录 Steam 后，“你的订阅”现在会列出已订阅的壁纸，“下载不在壁纸库中的项目”也能找到它们
- 读取本地文件的网页壁纸不再停留在加载画面
- 自带背景图片或视频的 Workshop 预设现在会显示这些内容，而不再是黑屏
- 启用可选的原生视频播放时，即使 Mac 的音频输出无法启动，视频壁纸也会继续无声播放，而不再切换到兼容播放
- 对于 macOS 一直拒绝设置静态壁纸的桌面，WallpaperMachine 不再无休止地重试，而是在切换到该桌面或 Mac 唤醒时再试
- Workshop 预设中的日夜切换开关现在会保持药丸形状并出现在预设指定的位置，且不再退出可选的原生 Metal 渲染器

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.4...v1.2.5

## 1.2.4 — 2026-10-04

### English

This release fixes many scene rendering problems, stops the control panel from freezing in Discover and keeps paused downloads across restarts

#### Improved

- Paused Steam Workshop and pixiv downloads now resume after you restart the app
- Wallpapers whose files change on disk now reload with the new content
- The app stays responsive while preparing an update, and update installations no longer overlap
- The Retry wallpaper button now appears only for web wallpapers whose page failed to load, while other errors stay visible
- The library repeats less work when it updates, and JPEG images decode faster on Apple silicon

#### Fixed

- The control panel no longer freezes repeatedly while animated previews play in Discover
- Switching wallpapers no longer needs repeated Apply clicks when background updates arrive during loading
- Software-decoded videos now show their frames instead of a black screen
- 3D scene characters no longer disappear, and scene cameras follow their intended shots, paths and field of view
- Intro animations now finish instead of leaving part of the wallpaper permanently covered
- Lit 2D scene artwork no longer loses its lighting and looks too dark
- Animated characters no longer appear over-lit or show patches around their eyes
- Hair, limbs and other puppet parts stay attached when animation layers overlap
- Nested cut-out layers such as heads and flowers now move together with their background during parallax
- 3D scenes no longer show large solid bands or repeated sprites, and thin lines keep their full strength
- Some scene effects that were previously missing now appear
- Transparent areas and soft edges in scenes are now preserved
- Live Solar System shows its bright sun again and no longer has an oversized dwarf planet covering the view
- The color picker now opens next to its control instead of at a mirrored position
- Some videos no longer play with the wrong orientation
- Imported wallpaper files are no longer lost after a failed write, overlapping imports or a cancelled selection
- Imports keep running when you cancel quitting the app
- Cancelled pixiv downloads no longer come back as paused after a crash
- Opening Your subscriptions in Discover without a Steam sign-in now offers Sign in to Steam instead of an old list with a Retry button that could never succeed

### 简体中文

此版本修复了大量场景渲染问题，解决了控制面板在“发现”中卡住的情况，并在重启后保留已暂停的下载

#### 改进

- 已暂停的 Steam Workshop 和 pixiv 下载现在会在重启应用后继续
- 磁盘上文件发生变化的壁纸现在会重新载入新内容
- 准备更新时应用保持响应，更新安装也不会再重叠进行
- “重试壁纸”按钮现在只在网页壁纸页面加载失败时显示，其他错误仍会保持可见
- 壁纸库更新时减少了重复工作，JPEG 图片在 Apple 芯片上解码更快

#### 修复

- 在“发现”中播放动态预览时，控制面板不再反复卡住
- 载入期间收到后台更新时，切换壁纸不再需要反复点击“应用”
- 软件解码的视频现在会显示画面，而不是黑屏
- 3D 场景中的角色不再消失，场景镜头也会按设定的机位、路径和视角播放
- 开场动画现在会完整播放，不再让壁纸的一部分一直被遮住
- 带光照的 2D 场景图像不再丢失光照而显得过暗
- 动画角色不再出现过度打光或眼睛周围的色块
- 多个动画层叠加时，头发、四肢等角色部件不再分离
- 头部、花朵等嵌套的剪贴图层在视差移动时现在会与背景一起移动
- 3D 场景不再出现大片纯色条带或重复的精灵图，细线也保持原有清晰度
- 一些之前缺失的场景特效现在会正常显示
- 场景中的透明区域和柔和边缘现在会被保留
- Live Solar System 重新显示明亮的太阳，也不再有过大的矮行星遮挡画面
- 颜色选择器现在会在其控件旁打开，而不是出现在上下颠倒的位置
- 部分视频不再以错误的方向播放
- 写入失败、导入重叠或取消选择后，已导入的壁纸文件不再丢失
- 取消退出应用时，导入会继续进行
- 已取消的 pixiv 下载在崩溃后不再以暂停状态重新出现
- 未登录 Steam 时在“发现”中打开“我的订阅”，现在会提供“登录 Steam”，而不是显示旧列表和一个永远无法成功的“重试”按钮

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.3...v1.2.4

## 1.2.3 — 2026-10-02

### English

SteamCMD now runs natively on Apple silicon, Workshop presets arrive with their base wallpapers, and many scene, web, video and multi-display problems are fixed

#### Breaking changes

- Existing Intel-only SteamCMD copies must be reinstalled from Settings → Library & Steam, and the app guides you through it

#### New

- Workshop presets can now be imported together with their base wallpaper, which downloads automatically if missing, as one self-contained library entry

#### Improved

- SteamCMD now installs and runs natively on Apple silicon without Rosetta, keeping your sign-in, saved sessions and Workshop downloads
- Download errors now recognize connection problems and rate limits instead of blaming your Steam credentials for unknown failures
- Pixiv downloads refused by the server now explain that access was denied instead of suggesting that a short wait will help

#### Fixed

- A deleted wallpaper assigned to one display no longer stops wallpapers from applying on other displays, and reinstalling it restores the assignment
- Web wallpapers that load WebAssembly from their own files, such as those built with Unity, now start correctly
- Video wallpapers in formats macOS cannot open itself, such as MKV, are no longer rejected and now try compatibility playback
- Scenes whose camera parallax has no delay no longer show a flat grey screen and now follow the cursor immediately
- With Compatibility rendering, some layers no longer show another layer's picture, such as a stained-glass window turning dark
- Web wallpapers that react to music now receive audio even when no scene wallpaper is running
- Brightness pulse effects in some scenes now stay inside the areas their authors intended instead of spreading across the picture
- When the experimental animated lock screen fails to start, your screen saver setting is now kept instead of being changed
- The frame rate slider in Performance can now cap at your display's full refresh rate, with No limit as its own position

### 简体中文

SteamCMD 现可在 Apple 芯片上原生运行，Workshop 预设会连同其基础壁纸一起导入，同时修复了场景、网页、视频和多显示器方面的诸多问题

#### 不兼容变更

- 现有的仅限 Intel 的 SteamCMD 需要在设置 → 壁纸库与 Steam 中重新安装，应用会引导你完成

#### 新增

- 现在可以将 Workshop 预设连同其基础壁纸一起导入，缺少的基础壁纸会自动下载，并合成为一个独立的壁纸库条目

#### 改进

- SteamCMD 现可在 Apple 芯片上原生安装和运行，无需 Rosetta，并保留你的登录状态、已保存会话和 Workshop 下载
- 下载错误现在能识别网络连接问题和频率限制，不再把未知故障归咎于你的 Steam 账号凭据
- 被服务器拒绝的 pixiv 下载现在会说明访问被拒绝，而不是提示稍等片刻即可解决

#### 修复

- 分配给某个显示器的壁纸被删除后不再导致其他显示器无法应用壁纸，重新安装该壁纸即可恢复分配
- 从自身文件加载 WebAssembly 的网页壁纸（例如使用 Unity 制作的壁纸）现在可以正常启动
- macOS 自身无法打开的视频壁纸格式（例如 MKV）不再被拒绝，现在会尝试使用兼容播放
- 相机视差没有延迟的场景不再显示为一片灰屏，现在会立即跟随光标移动
- 使用兼容渲染时，部分图层不再显示其他图层的画面，例如彩色玻璃窗变暗的问题
- 随音乐变化的网页壁纸现在即使没有运行场景壁纸也能获取音频
- 部分场景中的亮度脉冲效果现在会保持在作者设定的区域内，不再扩散到整个画面
- 实验性的动态锁定屏幕启动失败时，现在会保留你的屏幕保护程序设置，而不会将其更改
- 性能中的帧率滑块现在可以限制在显示器的完整刷新率，“无限制”单独作为一个档位

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.2...v1.2.3

## 1.2.2 — 2026-10-01

### English

This release adds wallpaper collections, playlists, presets and settings backups, and fixes several problems with restoring your original desktop and lock screen wallpapers

#### Breaking changes

- Workshop downloads now require a Steam account that owns Wallpaper Engine, and you can check again after buying it

#### New

- Organize installed wallpapers into your own collections and reusable playlists
- Save wallpaper properties as named presets, apply them anytime and exchange them with others
- Back up your settings and, optionally, your wallpaper files, then preview a restore before applying it and undo it if needed
- Mute web wallpapers and adjust media volume
- Position and zoom imported images separately on each display
- Choose which displays an action applies to in Shortcuts
- Wallpapers now come with an explanation of their compatibility

#### Fixed

- Quitting now restores your original wallpaper on each display and Space, even after a relaunch, and leaves the system wallpaper alone when no original can be recovered
- Quitting now waits for your original wallpaper to be restored and is cancelled with an error if restoring fails, instead of leaving a still frame behind
- After a cancelled quit, the desktop still frame resumes updating without needing another wallpaper or settings change
- The experimental animated lock screen can now be turned on when macOS shares its default wallpaper between the lock screen and screen saver
- Turning on only the experimental lock screen no longer times out when a Space inherits its wallpaper, and your screen saver choice is kept
- When lock screen wallpaper recovery fails because of damaged saved data, your wallpapers and recovery data are now kept so recovery can be retried

### 简体中文

此版本新增壁纸合集、播放列表、预设和设置备份，并修复了恢复原桌面和锁定屏幕壁纸时的多个问题

#### 不兼容变更

- Workshop 下载现在需要拥有 Wallpaper Engine 的 Steam 账户，购买后可重新检查

#### 新增

- 可将已安装的壁纸整理为自定义合集和可重复使用的播放列表
- 可将壁纸属性保存为命名预设，随时应用，并可与他人交换
- 可备份设置并选择是否包含壁纸文件，恢复前可预览，必要时还可撤销恢复
- 可将网页壁纸静音，并调节媒体音量
- 可在每台显示器上分别调整导入图片的位置和缩放
- 可在快捷指令中选择操作要应用到的显示器
- 壁纸现在附带兼容性说明

#### 修复

- 退出时会在每台显示器和每个空间恢复原壁纸，重新启动后也是如此；无法找回原壁纸时不再改动系统壁纸
- 退出时会等待原壁纸恢复完成；恢复失败时会取消退出并显示错误，不再留下静止画面
- 取消退出后，桌面静止画面会恢复更新，无需再次更换壁纸或修改设置
- 当 macOS 在锁定屏幕和屏幕保护程序之间共用默认壁纸时，现在也可以开启实验性的动态锁定屏幕
- 当空间沿用继承的壁纸时，仅开启实验性锁定屏幕不再超时，屏幕保护程序的选择也会保留
- 因保存的数据损坏导致锁定屏幕壁纸恢复失败时，现在会保留壁纸和恢复数据，以便重新尝试恢复

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.1...v1.2.2

## 1.2.1 — 2026-09-30

### English

This release adds an experimental option to use applied wallpapers as macOS screen savers, restores glow and live updates in scene wallpapers, and gives Settings a clearer, roomier layout

#### New

- Try an experimental setting on macOS 26 and later that shows applied scene, video, web and still wallpapers as screen savers and restores your previous choice when turned off
- What's New opens in a larger window with English and Simplified Chinese tabs and starts in the app's current language
- After you first apply a downloaded wallpaper, the app asks once whether you would like to star it on GitHub or become a Supporter, and is easy to dismiss

#### Improved

- All Settings pages have roomier spacing, cleaner separators and controls that stack in narrow windows, with library and installation paths shown full width
- Advanced performance controls are split into video, scene and experimental groups, with renderer choices first and running status in collapsible Live diagnostics sections
- The energy readout in Settings leads with total power and an energy grade, shows CPU and GPU separately and tucks details into an expandable section
- Workshop download errors now explain that a Steam account that purchased Wallpaper Engine is required, with guidance on buying it or switching accounts
- The experimental animated lock screen now shows a specific error when macOS loads an incompatible app copy or its configuration fails to load
- Expand and collapse arrows in Settings are bolder and easier to read, turning accent-colored when open
- The welcome guide's language picker has a balanced layout, with System (Auto) on its own row above equal language tiles

#### Fixed

- Scene wallpapers show bright glows, bloom and emissive highlights correctly again, and bloom no longer grows out of bounds
- Scene wallpapers with clocks, text, audio bars and interactive properties update live again
- Perspective scenes and full-screen effects render at the selected display resolution without losing texture detail, and translucent glows keep their backgrounds
- Scene wallpapers that rely on scripted layers, templates, hidden textures or perspective particles display their full content again
- Navigation in the control panel stays visible in full-screen and Split View, and the title bar returns normally on exit
- The Import file picker now matches the app language right after you change it, without restarting wallpapers
- The active display filter label in Installed stays on one line without being shrunk or cut off

### 简体中文

此版本新增实验性选项，可将已应用的壁纸用作 macOS 屏幕保护程序，恢复了场景壁纸的光晕效果与实时更新，并让设置页面布局更清晰、更宽松

#### 新增

- 在 macOS 26 及更高版本上可试用一项实验性设置，将已应用的场景、视频、网页和静态壁纸用作屏幕保护程序，关闭后恢复你之前的选择
- 新功能窗口现在以更大的尺寸打开，提供英文和简体中文标签页，并默认显示应用当前的语言
- 首次应用下载的壁纸后，应用会询问一次是否愿意在 GitHub 上加星或成为支持者，并且可以轻松关闭

#### 改进

- 所有设置页面的间距更宽松、分隔线更整洁，窄窗口中控件会纵向排列，壁纸库和安装路径以全宽显示
- 高级性能控件分为视频、场景和实验性三组，渲染器选项排在最前，运行状态放在可折叠的实时诊断区域中
- 设置中的能耗读数首先显示总功率和能耗等级，分别显示 CPU 和 GPU 读数，并将详细信息收进可展开的区域
- Workshop 下载出错时会说明需要已购买 Wallpaper Engine 的 Steam 账户，并提供购买或切换账户的指引
- 实验性动态锁定屏幕现在会在 macOS 加载了不兼容的应用副本或配置加载失败时显示具体错误
- 设置中的展开和折叠箭头更粗、更易辨认，展开时会显示强调色
- 欢迎向导中的语言选择器布局更均衡，“系统（自动）”单独占一行，下方为等宽的语言选项

#### 修复

- 场景壁纸重新正确显示明亮光晕、泛光和自发光高光，泛光也不再过度扩散
- 带有时钟、文字、音频条和交互属性的场景壁纸重新能够实时更新
- 透视场景和全屏效果按所选显示器分辨率渲染且不丢失纹理细节，半透明光晕后方的背景也得以保留
- 依赖脚本图层、模板、隐藏纹理或透视粒子的场景壁纸重新完整显示内容
- 控制面板的导航在全屏和分屏浏览中保持可见，退出后标题栏也会正常恢复
- 更改应用语言后，导入文件选择器会立即使用新语言，且无需重启壁纸
- 已安装中当前显示器筛选标签保持单行显示，不再被缩小或截断

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.2.0...v1.2.1

## 1.2.0 — 2026-09-29

### English

This release adds pixiv, playlists, Workshop updates and subscriptions, picture import, keyboard shortcuts and Shortcuts actions, and Traditional Chinese and Japanese, and makes the experimental animated lock screen more dependable.

#### New

- A new pixiv tab browses rankings and tag search with filters, and saves any illustration page to Installed as a still wallpaper
- Sign in to pixiv to see members-only works and, if your account allows it, choose to include R-18 works
- Settings → Displays gives each display a Playlist that rotates through all wallpapers, your favorites or its own list, in order or shuffled, from every 5 minutes to every day, or switches between a day and a night wallpaper
- Add wallpapers to a display's playlist from their details or a selection, and the menu bar's Next Wallpaper follows a rotating display's playlist
- Once a day the app asks Steam which of your installed Workshop wallpapers have been updated, sending only their ids; update one or all of them from Installed and they keep their settings, and Settings → Library & Steam can turn the check off
- Discover can browse Workshop collections, more wallpapers by an author and your Steam subscriptions, and download the subscribed wallpapers you don't have yet
- Import JPEG, PNG, GIF, WebP, HEIC, TIFF, BMP and AVIF pictures up to 512 MB as still wallpapers with Image fit and background colour options
- Drop files or folders on WallpaperMachine in the Dock, or open them with it from Finder, to import them
- Settings → General can record global keyboard shortcuts to play or pause wallpapers, go to the next wallpaper and open the control panel; none is set until you record one
- The Shortcuts app gains WallpaperMachine actions that Siri and Spotlight can run too, and the same commands work as wallpapermachine:// links
- Settings → Performance → Playback can pause or stop wallpapers in Low Power Mode or when the Mac is hot, off until you choose
- Add the WallpaperMachine Focus filter in System Settings to pause, mute or stop wallpapers while a Focus is on
- WallpaperMachine is now also in Traditional Chinese and Japanese, chosen in Settings → General → Language or used automatically when your Mac is set to one of them
- After an update, a What's New window lists the changes since your previous version in English and Simplified Chinese, and can be turned off

#### Fixed

- The experimental animated lock screen now resumes where it left off after the display wakes, instead of reloading and restarting its animation
- The experimental animated lock screen no longer briefly shows the background behind the wallpaper
- The experimental animated lock screen no longer clears its wallpaper when displays are connected, removed or change resolution
- A waking display shows black instead of white until its wallpaper draws again
- Wallpapers are no longer reset when a display wakes and macOS only moves their windows

### 简体中文

此版本新增 pixiv、播放列表、创意工坊更新与订阅、图片导入、键盘快捷键与快捷指令操作，以及繁体中文和日语，并让实验性的动态锁定屏幕更加可靠。

#### 新增

- 新增 pixiv 标签页，可按条件筛选浏览排行榜和标签搜索，并将任意插画页面保存到已安装，作为静态壁纸使用
- 登录 pixiv 后可查看仅限会员的作品，若账户允许，还可选择显示 R-18 作品
- 设置 → 显示器为每台显示器提供播放列表，可在全部壁纸、个人收藏或它自己的列表中按顺序或随机轮换，间隔从 5 分钟到 1 天，也可在白天和夜晚各显示一张壁纸
- 可从壁纸详情或多选中把壁纸加入显示器的播放列表，菜单栏的“下一张壁纸”会跟随正在轮换的显示器的播放列表
- 应用每天向 Steam 查询一次已安装的创意工坊壁纸是否有更新，只发送壁纸 ID；可在已安装中更新单个或全部壁纸，壁纸设置会保留，也可在 设置 → 壁纸库与 Steam 中关闭检查
- 发现页可以浏览创意工坊合集、作者的更多作品和你的 Steam 订阅，并可下载库中还没有的订阅壁纸
- 可导入最大 512 MB 的 JPEG、PNG、GIF、WebP、HEIC、TIFF、BMP 和 AVIF 图片作为静态壁纸，并可设置图像适配方式和背景颜色
- 将文件或文件夹拖到程序坞中的 WallpaperMachine 上，或在访达中用它打开，即可导入
- 设置 → 通用可录制全局键盘快捷键，用于播放或暂停壁纸、切换到下一张壁纸和打开控制面板，录制之前不会设置任何快捷键
- 快捷指令 App 新增 WallpaperMachine 操作，Siri 和聚焦搜索也能运行，同样的命令也可以通过 wallpapermachine:// 链接调用
- 设置 → 性能 → 播放新增选项，可在低电量模式下或 Mac 过热时暂停或停止壁纸，选择前默认关闭
- 在系统设置中添加 WallpaperMachine 的专注模式过滤条件，即可在专注模式开启时暂停、静音或停止壁纸
- WallpaperMachine 新增繁体中文和日语，可在 设置 → 通用 → 语言 中选择，Mac 使用这两种语言时也会自动采用
- 更新后会显示“更新内容”窗口，用中英双语列出自上个版本以来的变化，也可以关闭

#### 修复

- 实验性的动态锁定屏幕在显示器唤醒后会从中断处继续播放，不再重新加载并从头开始动画
- 实验性的动态锁定屏幕不再短暂露出壁纸下方的背景
- 连接、移除显示器或更改分辨率时，实验性的动态锁定屏幕不再清除壁纸
- 显示器唤醒时，壁纸重新绘制之前显示黑色而不是白色
- 显示器唤醒且 macOS 只是移动壁纸窗口时，壁纸不再被重置

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.1.0...v1.2.0

## 1.1.0 — 2026-09-28

### English

Wallpapers now pause when windows cover the desktop and use less memory, and actions queue and run in order instead of showing an error.

#### New

- Wallpapers pause when windows cover the desktop and resume once any of it shows, set in Settings → Performance → Playback with Pause as default or Keep running

#### Improved

- Actions from the control panel and menu bar now queue and run in order, and clicking several wallpapers in a row applies the last one
- The tile being applied shows a progress ring, and wallpapers queued behind it are marked
- Wallpapers use less memory by loading textures sized for your display and releasing renderers and allocations they are not using
- The experimental animated lock screen keeps a still poster while unlocked and loads its scene only when it can be shown
- Discover releases preview animations for tiles scrolled out of view, and the control panel frees its web resources when closed
- Favorites, Show in Finder and the delete confirmation no longer wait for or hold up other actions
- The default frame rate limit is now 60 fps

#### Fixed

- Switching wallpapers while another action was running no longer shows a red "Wait for the current action to finish" banner
- Frame rate limits now reach their target, where a 60 fps limit previously delivered about 50 frames a second
- Library refreshes after downloads and imports no longer fail while a wallpaper is being applied
- The Updates and license cards in Settings → About now leave the same space below their last line as other cards

### 简体中文

窗口盖住桌面时壁纸会暂停，并且占用更少内存；各项操作会排队按顺序执行，而不再显示错误。

#### 新增

- 窗口盖住桌面时壁纸会暂停，一旦桌面有任何部分露出就恢复。可在设置 → 性能 → 播放中设置，默认为“暂停”，也可选“继续运行”

#### 改进

- 控制面板和菜单栏中的操作现在会排队按顺序执行；连续点击多张壁纸时，会应用最后点的那一张
- 正在应用的磁贴会显示进度环，排在它后面的壁纸也会被标出
- 壁纸会按你的显示器尺寸加载纹理，并释放未在使用的渲染器和内存分配，从而占用更少内存
- 实验性的锁定屏幕动态壁纸在未锁定时保持一张静止海报，只在能够显示时才加载场景
- “发现”会释放滚出视野的磁贴预览动画；控制面板关闭时会释放它的网页资源
- 收藏、“在访达中显示”和删除确认不再等待其他操作，也不再挡住它们
- 默认帧率上限现在是 60 fps

#### 修复

- 在另一项操作进行中切换壁纸时，不再显示红色的“请等待当前操作完成”横幅
- 帧率上限现在能达到设定目标；以前设为 60 fps 时，大约只有每秒 50 帧
- 正在应用壁纸时，下载和导入之后的壁纸库刷新不再失败
- 设置 → 关于中的更新卡片和许可证卡片，最后一行下方现在留出与其他卡片相同的间距

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.0.3...v1.1.0

## 1.0.3 — 2026-09-28

### English

This release stops wallpapers from flashing and restarting after unlocking, makes Restart to Update work again, and keeps the control panel open after you apply a wallpaper.

#### Breaking changes

- Applying a wallpaper no longer hides the control panel by default; a choice already made in Settings → General → Hide window after applying a wallpaper is kept

#### New

- File → Close (Command-W) now closes the control panel, like its close button, while the app keeps running in the menu bar

#### Improved

- Apply and Quit respond promptly even while the app is handling a burst of updates, such as after unlocking the Mac
- Update checks no longer use up GitHub's hourly limit on anonymous requests, which is shared by every device on the same network

#### Fixed

- Wallpapers no longer flash white and restart their opening animation again and again after unlocking the Mac, a problem introduced in 1.0.2
- Restart to Update now quits and reopens on the new version instead of closing the window and doing nothing
- With the experimental Animate Lock Screen on, macOS 15 and later no longer asks at every launch to allow access to data from other apps
- The experimental animated lock screen keeps moving when you lock the Mac instead of showing a still frame
- Applying a wallpaper, changing a display setting or switching the video backend no longer reloads unchanged wallpapers on other displays, which made them flash white
- A wallpaper applied while a frame-rate cap is on now starts at the capped rate
- About no longer reports a connection failure when GitHub's hourly update-check limit runs out; it says when the limit resets and waits until then

### 简体中文

此版本让解锁后壁纸不再闪一下并重新开始，使“重启并更新”重新可用，并在你应用壁纸后保持控制面板打开。

#### 不兼容变更

- 应用壁纸后默认不再隐藏控制面板；若已在设置 → 通用 → 应用壁纸后隐藏窗口中做过选择，该选择会保留

#### 新增

- 文件 → 关闭（Command-W）现在会关闭控制面板，与它的关闭按钮一样，应用仍在菜单栏中继续运行

#### 改进

- 即使应用正在处理一阵密集的更新，例如解锁 Mac 之后，“应用”和“退出”也会及时响应
- 更新检查不再用尽 GitHub 对匿名请求的每小时限额；该限额由同一网络上的每台设备共享

#### 修复

- 解锁 Mac 后，壁纸不再反复闪白并重新播放开场动画；这个问题是 1.0.2 引入的
- “重启并更新”现在会退出并在新版本上重新打开，而不再只是关掉窗口、什么也不做
- 开启实验性的“锁定屏幕动态壁纸”后，macOS 15 及更高版本不再在每次启动时询问是否允许访问其他 App 的数据
- 锁定 Mac 时，实验性的锁定屏幕动态壁纸会继续播放，而不再停在一帧上
- 应用壁纸、更改显示器设置或切换视频后端时，不再重新加载其他显示器上没有变化的壁纸，那些壁纸因此不再闪白
- 在帧率上限开启时应用的壁纸，现在会以该上限速率开始
- GitHub 每小时的更新检查限额用尽时，“关于”不再报告连接失败；它会说明限额何时重置，并等到那时

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.0.2...v1.0.3

## 1.0.2 — 2026-09-27

### English

WallpaperMachine 1.0.2 adds drag selection in Installed, makes in-app updates safer and keeps macOS privacy permissions across updates. Wallpapers and the control panel also do less repeated and background work.

#### New

- Hold a tile in Installed and drag across others to select a run of wallpapers, with auto-scroll at the edges
- A tip in the selection row explains drag selection until you use it once or dismiss it

#### Improved

- Wallpapers skip redrawing frames that would repeat an unchanged picture, and scenes follow the Scene render optimisation setting for this
- Sound output starts only while a wallpaper is playing unmuted, and system audio is captured only for scenes or web wallpapers that use it
- Paused or covered scenes stop tracking the pointer, and web wallpapers track it only while a page is live
- Video and scene playback do less background work, with fewer decode wakes and hidden particles skipped while their simulation continues
- The control panel does less work while inactive, and Discover samples colours only while it is visible
- Reselecting the same lock screen wallpaper no longer repeats the compatibility check
- Tiles in Installed no longer enlarge on hover

#### Fixed

- Restarting to install an update no longer removes the current version first, and reopens the previous version if the install fails
- macOS privacy permissions granted to the app are no longer lost after an update
- Scene wallpapers no longer risk failing when their display surface is replaced while the scene is still loading at startup

### 简体中文

WallpaperMachine 1.0.2 在“已安装”中增加拖拽选择，让应用内更新更安全，并在更新后保留 macOS 隐私权限。壁纸和控制面板也会减少重复的工作和后台工作。

#### 新增

- 在“已安装”中按住一张磁贴并拖过其他磁贴，即可选中连续的一段壁纸，拖到边缘时会自动滚动
- 选择行里的提示会说明拖拽选择，直到你使用过一次或关掉它

#### 改进

- 壁纸会跳过只会重复未变化画面的重绘；场景是否这样做，遵循“场景渲染优化”设置
- 只有壁纸正在播放且未静音时才开始输出声音；只有使用系统音频的场景或网页壁纸才会采集它
- 已暂停或被盖住的场景不再跟踪指针；网页壁纸只在页面处于活动状态时跟踪指针
- 视频和场景播放减少后台工作：解码唤醒更少，隐藏的粒子在其模拟继续时会被跳过
- 控制面板在不活动时少做工作；“发现”只在可见时采样颜色
- 再次选择同一张锁屏壁纸时，不再重复兼容性检查
- “已安装”中的磁贴在悬停时不再放大

#### 修复

- 为安装更新而重启时，不再先移除当前版本；如果安装失败，会重新打开先前的版本
- 授予本应用的 macOS 隐私权限在更新后不再丢失
- 启动时如果场景仍在加载、其显示表面被替换，场景壁纸不再因此可能失败

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.0.1...v1.0.2

## 1.0.1 — 2026-09-27

### English

WallpaperMachine now checks for updates on its own, adds a rebuilt Performance page with an energy readout and battery options, and fixes a launch crash after changing the render scale.

#### New

- WallpaperMachine checks for updates after the library loads and every six hours, and where it can update in place it downloads them and offers Restart to Update
- WallpaperMachine runs on macOS 15 Sequoia
- Settings → Performance shows the app's CPU and GPU power, a grade, its share of the battery and a before/after comparison when you change a setting
- On battery you can choose to keep running, drop to a render scale and frame rate you pick, or pause, and this stays off until you choose
- Playback rules can pause or mute wallpapers while chosen apps are frontmost or another app is playing audio
- The menu bar item adds Next Wallpaper, which applies the next playable library wallpaper to the target display, and Lock Screen
- Settings → General adds Hide window after applying a wallpaper, on by default, which you can turn off to keep the window open for previewing
- The inspector shows each wallpaper's energy rating
- Settings can save a redacted diagnostics report to attach to a GitHub issue
- The welcome guide gains a Performance step

#### Improved

- Settings → Performance is rebuilt as a single page covering energy use first, then quality, then playback
- The frame-rate cap now follows the display's native refresh rate by default
- A display that goes to sleep now stops its wallpaper
- After choosing Later on an update, the menu bar item keeps offering it until the app restarts

#### Fixed

- The app no longer crashes at launch right after applying a render scale
- Reopening the app from the Dock now keeps you on the page you were viewing

### 简体中文

WallpaperMachine 现在会自行检查更新，新增了重建后的“性能”页面，带有能耗读数和电池选项，并修复了更改渲染比例后启动崩溃的问题。

#### 新增

- WallpaperMachine 会在壁纸库加载后以及每隔六小时检查更新；在能够就地更新时会下载更新，并提供“重启并更新”
- WallpaperMachine 可在 macOS 15 Sequoia 上运行
- 设置 → 性能显示本应用的 CPU 和 GPU 功耗、等级、占电池的比例，以及你更改一项设置时的前后对比
- 使用电池时，可以选择继续运行、降到你选定的渲染比例和帧率，或暂停；在你选择之前，此功能保持关闭
- 播放规则可以在所选应用位于最前，或其他应用正在播放音频时，暂停或静音壁纸
- 菜单栏项目增加了“下一张壁纸”和“锁定屏幕”。“下一张壁纸”会把壁纸库中下一张可播放的壁纸应用到目标显示器
- 设置 → 通用增加了“应用壁纸后隐藏窗口”，默认开启；可以关掉它，以便预览时保持窗口打开
- 壁纸详情显示每张壁纸的能耗等级
- 设置可以保存一份已脱敏的诊断报告，以便附到 GitHub issue
- 欢迎指南增加了一个“性能”步骤

#### 改进

- 设置 → 性能重建为单一页面，依次涵盖能耗、画质和播放
- 帧率上限现在默认跟随显示器的原生刷新率
- 进入睡眠的显示器现在会停止它的壁纸
- 在更新提示上选择“稍后”之后，菜单栏项目会一直提供该更新，直到应用重启

#### 修复

- 刚应用渲染比例之后，应用在启动时不再崩溃
- 从程序坞重新打开应用时，会留在你正在查看的页面

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v1.0.0...v1.0.1

## 1.0.0 — 2026-09-26

### English

WallpaperMachine 1.0 ships as a drag-to-install disk image and adds a first-run guide with Steam sign-in, optional now-playing support for music wallpapers and many scene rendering fixes.

#### New

- Downloads and in-app updates now come as a drag-to-install disk image with first-launch steps under System Settings → Privacy & Security → Open Anyway
- A first-run welcome guide sets language and appearance, signs in to Steam and shares tips, and can be reopened from Settings → Library & Steam
- Music wallpapers can optionally show the current track, cover art and playback state from your Mac's now-playing information once you allow media access
- Play, pause, next and previous buttons inside music wallpapers can now control the player you are using, starting on the action the button's name suggests
- Choose how many Workshop downloads run at once in Settings → Library & Steam → Downloads at once, from 1 to 6
- Settings → General has a Language picker for System (Auto), English and Simplified Chinese that switches the panel in place
- The control panel has a Wallpaper Engine-style filter sidebar with Workshop filters for type, age rating, resolution and tags, plus more Discover sort orders
- Installed can be filtered with the same sidebar boxes as Discover and sorted by name, type, favorites, file size or date added
- Wallpapers that let you choose your own picture now show the picture you pick instead of the packaged artwork
- Tiles show corner marks for staff-approved items, favorites and wallpapers already in your library
- Report a problem on GitHub now opens with the wallpaper's details filled in
- Choose between new branded app icons
- Settings → About shows what changed in the newest release
- The optional Native Metal renderer now draws effects, video, text layers, puppets, particle trails and sprite sheets

#### Improved

- Scenes with many large images open much faster because their images are decoded once and in parallel
- Newly connected displays start enabled with the main display's wallpaper, and turning one off is remembered across reconnections
- The Discover download ring names the current step, such as Connecting or Signing in, and shows Finishing while files are checked and imported
- Discover previews download once, are kept on disk and play sooner, and resizing the window no longer reloads the page
- The frame rate limit you set is now respected by wallpapers that react to the pointer
- Changing tracks on a music wallpaper no longer reloads the whole wallpaper or restarts its videos
- Heavy 3D wallpapers get more time to show their first frame, and later launches reach it faster
- Scene wallpapers do less redundant drawing work while playing
- Control panel text is rewritten in plain language and every message, menu and error is now translated into Simplified Chinese
- Checking for updates no longer reports an error when no release has been published yet

#### Fixed

- Wallpapers no longer disappear when you hide the app with Cmd-H or after activating a wallpaper
- The app restores your own wallpapers at launch instead of posters or selections inherited from another display
- Scene video textures no longer freeze after half a second, and 4K video scenes no longer fail with no first frame
- The internal render scale setting now takes effect on scene wallpapers
- Wallpaper buttons no longer stay stuck shrunk after being pressed
- Sounds bound to a wallpaper's volume slider now follow the slider
- Camera intros in 2D scenes play, and masked or parallax layers stay in place instead of sliding out of view
- 2D wallpapers with a camera layer no longer show only a small patch in one corner
- Blurred layers no longer flatten into a grey wash in the Compatibility renderer
- Effects written for Wallpaper Engine that were silently dropped now appear on their layers
- Audio-responsive elements react to sound on the Native Metal renderer instead of turning black
- Heavy 3D scenes no longer collapse to a column or lose skies, rings and large meshes
- Mouse trails follow the cursor near screen edges instead of drifting away from it
- Parallax no longer pushes grouped layers aside and uncovers what is beneath them
- Scripted dock icons in wallpapers now scale, fade and open as intended
- Album covers keep their authored shape instead of turning into circles
- Music wallpapers no longer go blank after changing a setting until playback is paused and resumed
- The lock screen status row now shows the real reason the experimental animated lock screen failed to start
- Applying a wallpaper no longer turns a mirrored display back into an independent one
- Installed tiles no longer show a leftover Discover preview animation
- Web wallpaper options keep their types and authored order
- Some control panel error messages no longer appear in English when the panel is in Chinese

### 简体中文

WallpaperMachine 1.0 以拖拽安装的磁盘映像发布，并增加了带 Steam 登录的首次运行指南、音乐壁纸可选的“正在播放”支持，以及多项场景渲染修复。

#### 新增

- 下载和应用内更新现在以拖拽安装的磁盘映像提供，首次启动的步骤在系统设置 → 隐私与安全性 → 仍要打开
- 首次运行的欢迎指南用于设置语言和外观、登录 Steam 并提供使用提示，可从设置 → 壁纸库与 Steam 重新打开
- 允许媒体访问后，音乐壁纸可以选择显示 Mac“正在播放”信息中的当前曲目、封面和播放状态
- 音乐壁纸内的播放、暂停、下一首和上一首按钮现在可以控制你正在使用的播放器，并从按钮名称所表示的操作开始
- 可在设置 → 壁纸库与 Steam → 同时下载数中选择同时进行的创意工坊下载数，从 1 到 6
- 设置 → 通用有语言选择器，可选“跟随系统（自动）”、English 和简体中文，并就地切换面板
- 控制面板有 Wallpaper Engine 风格的筛选侧边栏，创意工坊可按类型、年龄分级、分辨率和标签筛选，“发现”还有更多排序方式
- “已安装”可用与“发现”相同的侧边栏条件筛选，并按名称、类型、收藏、文件大小或添加日期排序
- 允许自选图片的壁纸现在会显示你选的图片，而不是自带的配图
- 磁贴会为工作人员认可的项目、收藏，以及已在壁纸库中的壁纸显示角标
- 在 GitHub 上反馈问题现在会打开，并填入该壁纸的详情
- 可在新的品牌应用图标之间选择
- 设置 → 关于会显示最新版本改了什么
- 可选的原生 Metal 渲染器现在可以绘制效果、视频、文字图层、木偶、粒子拖尾和精灵表

#### 改进

- 含有许多大图的场景打开快得多，因为图片只解码一次，并且并行解码
- 新连接的显示器一开始就是启用的，并使用主显示器的壁纸；关掉某一台会在重新连接后仍然记住
- “发现”的下载环会标出当前步骤，例如“连接中”或“登录中”，并在检查和导入文件时显示“收尾中”
- “发现”的预览只下载一次、保存在磁盘上并更早开始播放；调整窗口大小不再重新加载页面
- 你设置的帧率上限现在对响应指针的壁纸同样生效
- 在音乐壁纸上换曲不再重新加载整张壁纸，也不再重新开始其中的视频
- 较重的 3D 壁纸有更多时间来显示第一帧，之后的启动也会更快到达第一帧
- 场景壁纸播放时减少多余的绘制
- 控制面板文案改写成通俗语言，每条消息、菜单和错误现在都译成了简体中文
- 尚未发布任何版本时，检查更新不再报告错误

#### 修复

- 用 Cmd-H 隐藏应用后，或激活一张壁纸后，壁纸不再消失
- 启动时应用会恢复你自己的壁纸，而不是海报或从另一台显示器继承的选择
- 场景视频纹理不再在半秒后卡住，4K 视频场景也不再因为没有第一帧而失败
- 内部渲染比例设置现在对场景壁纸生效
- 壁纸按钮按下后不再一直保持缩小
- 绑定到壁纸音量滑块的声音现在会跟随滑块
- 2D 场景中的摄像机开场会播放；遮罩图层和视差图层留在原位，而不再滑出视野
- 带摄像机图层的 2D 壁纸不再只在一个角落显示一小块
- 在兼容模式渲染器中，模糊图层不再糊成一片灰色
- 为 Wallpaper Engine 编写、以前被静默丢弃的效果现在会出现在对应图层上
- 在原生 Metal 渲染器上，随音频变化的元素会响应声音，而不再变成黑色
- 较重的 3D 场景不再塌成一列，也不再丢失天空、环和大网格
- 鼠标拖尾在靠近屏幕边缘时会跟随光标，而不再从光标飘开
- 视差不再把成组的图层推开，也不再露出它们下面的内容
- 壁纸中由脚本控制的程序坞图标现在会按预期缩放、淡化和打开
- 专辑封面保持作者设定的形状，而不再变成圆形
- 更改设置后，音乐壁纸不再变成空白，不必等到暂停再继续播放才恢复
- 锁屏状态行现在会显示实验性锁定屏幕动态壁纸未能启动的真实原因
- 应用壁纸不再把镜像显示器变回独立显示器
- “已安装”磁贴不再显示残留的“发现”预览动画
- 网页壁纸的选项保持其类型和作者设定的顺序
- 面板为中文时，部分控制面板错误信息不再显示为英文

**Full changelog**: https://github.com/WallpaperMachine/WallpaperMachine/compare/v0.5.0...v1.0.0

## 0.5.0 — 2026-09-18

### English

#### New

- **panel** — Steam sign-in guides, logout wording, filter rail and top bar ([`bda404d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/bda404d))
- **scene,web** — Static subgraph reuse, web audio/media APIs, user file properties ([`dd01e58`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/dd01e58))
- **quality** — Internal render scale, quality settings, shared video decode ([`48b8df2`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/48b8df2))
- **native video** — Enhance rejectNativeVideo method with admission key and update related structures ([`47b12b1`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/47b12b1))
- **native video** — Implement native video wallpaper support and diagnostics ([`c0461f7`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0461f7))
- **presentation** — Enhance wallpaper suspension with per-display control ([`e39f0c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e39f0c4))

Plus 2 documentation, test and tooling commits.

### 简体中文

#### 新增

- **panel** — Steam 登录引导、退出登录文案、筛选栏和顶栏 ([`bda404d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/bda404d))
- **scene,web** — 静态子图复用、网页音频/媒体 API、用户文件属性 ([`dd01e58`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/dd01e58))
- **quality** — 内部渲染比例、画质设置、共享视频解码 ([`48b8df2`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/48b8df2))
- **native video** — 增强 rejectNativeVideo 方法，为其加入 admission key，并更新相关结构 ([`47b12b1`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/47b12b1))
- **native video** — 实现原生视频壁纸支持与诊断 ([`c0461f7`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0461f7))
- **presentation** — 增强壁纸暂停，支持按显示器控制 ([`e39f0c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e39f0c4))

另有 2 个文档、测试和工具相关的提交。

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.4.0...v0.5.0

## 0.4.0 — 2026-09-18

### English

#### New

- **workshop** — Concurrent downloads, tile download rings and grid-sized Discover pages ([`b0eaeed`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0eaeed))
- **panel** — Batch deletion, cached thumbnails, resizable layout and display names ([`6dc8c32`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/6dc8c32))

#### Fixed

- **renderer** — Drive vector material timelines and their events ([`511f59d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/511f59d))

#### Performance

- **playback** — Reduce steady-state rendering and input work ([`084c054`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/084c054))

### 简体中文

#### 新增

- **workshop** — 并发下载、磁贴下载环，以及按网格尺寸分页的“发现”页面 ([`b0eaeed`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0eaeed))
- **panel** — 批量删除、缓存的缩略图、可调整大小的布局和显示器名称 ([`6dc8c32`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/6dc8c32))

#### 修复

- **renderer** — 驱动矢量材质的时间线及其事件 ([`511f59d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/511f59d))

#### 性能

- **playback** — 减少稳态下的渲染和输入工作 ([`084c054`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/084c054))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.2...v0.4.0

## 0.3.2 — 2026-09-17

### English

#### New

- **web** — Host web wallpapers in WKWebView with mouse input ([`42a8fd8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/42a8fd8))

#### Fixed

- **scene** — Map cursor input through the presented wallpaper ([`3bb8899`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3bb8899))
- **renderer** — Script side-effect writes, puppet animation layers, cursor coverage ([`2385923`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/2385923))

Plus 1 documentation, test and tooling commit.

### 简体中文

#### 新增

- **web** — 在 WKWebView 中承载网页壁纸，并支持鼠标输入 ([`42a8fd8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/42a8fd8))

#### 修复

- **scene** — 经当前呈现的壁纸映射光标输入 ([`3bb8899`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3bb8899))
- **renderer** — 脚本副作用写入、木偶动画图层、光标覆盖范围 ([`2385923`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/2385923))

另有 1 个文档、测试和工具相关的提交。

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.1...v0.3.2

## 0.3.1 — 2026-09-16

### English

#### Fixed

- **updates** — Restore Settings About check-for-updates controls ([`3a653ec`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a653ec))

#### Other changes

- Update property-script evaluation to persist state across frames ([`169eba6`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/169eba6))
- **workspace** — Reorganize the tree and build a documentation set ([`518ff23`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/518ff23))

Plus 1 documentation, test and tooling commit.

### 简体中文

#### 修复

- **updates** — 恢复设置 → 关于中的检查更新控件 ([`3a653ec`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a653ec))

#### 其他变更

- 更新属性脚本的求值，使状态在帧与帧之间保持 ([`169eba6`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/169eba6))
- **workspace** — 重组目录树并建立一套文档 ([`518ff23`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/518ff23))

另有 1 个文档、测试和工具相关的提交。

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.3.0...v0.3.1

## 0.3.0 — 2026-09-16

### English

#### New

- **appearance** — Add light theme, system adaptation and customization ([`07ba75e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/07ba75e))
- **downloads** — Report real transfer speed and byte progress ([`d22b49b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d22b49b))

#### Fixed

- **downloads** — Expose NetworkReceiveMeter initializer ([`fca8f87`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fca8f87))
- **text** — Center each line inside the layer box ([`4cb3819`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/4cb3819))
- **scene** — Leave callback-only property scripts on their base value ([`8a09bd9`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8a09bd9))
- **scene** — Drive the global camera from the general.zoom animation ([`c0a9641`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0a9641))
- **mdl** — Keep the authored MDLS3 skeleton and pivots ([`463b4c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/463b4c4))

#### Other changes

- 0.3.0 ([`fadecdb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fadecdb))
- Optimize continuous playback resource reuse ([`8f53466`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8f53466))
- Reduce idle wallpaper background work ([`b03f6c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b03f6c4))

Plus 2 documentation, test and tooling commits.

### 简体中文

#### 新增

- **appearance** — 增加浅色主题、跟随系统以及自定义 ([`07ba75e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/07ba75e))
- **downloads** — 报告真实的传输速度和字节进度 ([`d22b49b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d22b49b))

#### 修复

- **downloads** — 公开 NetworkReceiveMeter 的初始化器 ([`fca8f87`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fca8f87))
- **text** — 使每一行在图层框内居中 ([`4cb3819`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/4cb3819))
- **scene** — 让仅含回调的属性脚本保持在其基础值上 ([`8a09bd9`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8a09bd9))
- **scene** — 由 general.zoom 动画驱动全局摄像机 ([`c0a9641`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/c0a9641))
- **mdl** — 保留作者设定的 MDLS3 骨架和枢轴 ([`463b4c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/463b4c4))

#### 其他变更

- 0.3.0 ([`fadecdb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/fadecdb))
- 优化连续播放时的资源复用 ([`8f53466`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8f53466))
- 减少空闲壁纸的后台工作 ([`b03f6c4`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b03f6c4))

另有 2 个文档、测试和工具相关的提交。

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.2.1...v0.3.0

## 0.2.1 — 2026-09-16

### English

#### Fixed

- **lockscreen** — Always hand the desktop back to the poster provider ([`9e21b68`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9e21b68))
- Keep Workshop page turns off the main tab path ([`7525e25`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7525e25))

#### Other changes

- 0.2.1 ([`7180677`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7180677))
- Fix presentation suspension and frame timing regressions ([`f56e00d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/f56e00d))
- Add WallpaperPresentationPolicy to suspend rendering when occluded ([`7db2382`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7db2382))

Plus 1 documentation, test and tooling commit.

### 简体中文

#### 修复

- **lockscreen** — 始终把桌面交还给海报提供方 ([`9e21b68`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9e21b68))
- 使创意工坊的翻页不经过主标签路径 ([`7525e25`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7525e25))

#### 其他变更

- 0.2.1 ([`7180677`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7180677))
- 修复呈现暂停和帧计时的回归 ([`f56e00d`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/f56e00d))
- 增加 WallpaperPresentationPolicy，在被遮挡时暂停渲染 ([`7db2382`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7db2382))

另有 1 个文档、测试和工具相关的提交。

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.2.0...v0.2.1

## 0.2.0 — 2026-09-15

### English

#### Other changes

- 0.2.0 ([`ccda129`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ccda129))
- Replace native SwiftUI panels with the WebKit control panel ([`7b83b4e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7b83b4e))

### 简体中文

#### 其他变更

- 0.2.0 ([`ccda129`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ccda129))
- 用 WebKit 控制面板替换原生 SwiftUI 面板 ([`7b83b4e`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/7b83b4e))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.8...v0.2.0

## 0.1.8 — 2026-09-15

### English

#### Other changes

- Hand the staging claim to SteamCMD and fail closed without it ([`180fc3c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/180fc3c))
- Require proof nothing is writing before reclaiming staging ([`8ac6f88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8ac6f88))
- Reclaim download staging stranded by a crash ([`eeb5e88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eeb5e88))
- Pin the Download Details sheet environment with an offscreen test ([`57aa2eb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/57aa2eb))

### 简体中文

#### 其他变更

- 把暂存认领交给 SteamCMD，没有它时按失败关闭处理 ([`180fc3c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/180fc3c))
- 在回收暂存区之前，要求证明没有任何写入 ([`8ac6f88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/8ac6f88))
- 回收因崩溃而滞留的下载暂存区 ([`eeb5e88`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eeb5e88))
- 用离屏测试固定“下载详情”表单所读取的环境 ([`57aa2eb`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/57aa2eb))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.5...v0.1.8

## 0.1.5 — 2026-09-15

### English

#### Other changes

- Give sheet content the environment it reads ([`3987685`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3987685))

### 简体中文

#### 其他变更

- 向表单内容提供它所读取的环境 ([`3987685`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3987685))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.4...v0.1.5

## 0.1.4 — 2026-09-15

### English

#### Other changes

- Drop the download mark from the private SteamCMD copy ([`15cf07f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/15cf07f))

### 简体中文

#### 其他变更

- 从私有的 SteamCMD 副本中去掉下载标记 ([`15cf07f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/15cf07f))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.3...v0.1.4

## 0.1.3 — 2026-09-15

### English

#### Other changes

- Keep the library grid out of the type checker's limit ([`59857dd`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/59857dd))
- Validate SteamCMD the way dyld does and build releases in CI ([`b0bc639`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0bc639))

### 简体中文

#### 其他变更

- 让壁纸库网格避开类型检查器的上限 ([`59857dd`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/59857dd))
- 按 dyld 的方式校验 SteamCMD，并在 CI 中构建发布版本 ([`b0bc639`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/b0bc639))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.1...v0.1.3

## 0.1.1 — 2026-09-15

### English

#### Other changes

- Fix one-click SteamCMD install for signed CLI tools and updater links ([`3a4033b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a4033b))

### 简体中文

#### 其他变更

- 修复已签名命令行工具和更新器链接的一键 SteamCMD 安装 ([`3a4033b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3a4033b))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/compare/v0.1.0...v0.1.1

## 0.1.0 — 2026-09-15

### English

#### Other changes

- Remove unused updater leftovers and ignore local verification artifacts ([`eb72174`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eb72174))
- Add confirmed GitHub Release updates so installed builds can download and restart-install ([`3338eb8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3338eb8))
- Add version bump CI triggered by release: commits ([`d882916`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d882916))
- Improve native wallpaper workflows and SteamCMD installation ([`aa7c22c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/aa7c22c))
- Integrate native lock-screen wallpapers and harden audio capture lifecycle ([`ecfe88f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ecfe88f))
- Document native verification, renderer probes, and desktop tooling ([`311ab7a`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/311ab7a))
- Queue concurrent Workshop downloads and safely adopt completed imports ([`db27a08`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/db27a08))
- Fix renderer compatibility and render-target lifetime regressions ([`e455b6b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e455b6b))
- Publish complete project snapshot including completed agent changes ([`1fb3048`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/1fb3048))
- Publish initial source snapshot excluding concurrent agent work ([`9f33787`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9f33787))

### 简体中文

#### 其他变更

- 移除未使用的更新器残留，并忽略本地验证产物 ([`eb72174`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/eb72174))
- 增加已经确认的 GitHub Release 更新，使已安装的构建可以下载并重启安装 ([`3338eb8`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/3338eb8))
- 增加由 release: 提交触发的版本号提升 CI ([`d882916`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/d882916))
- 改进原生壁纸流程和 SteamCMD 安装 ([`aa7c22c`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/aa7c22c))
- 集成原生锁屏壁纸，并加固音频采集的生命周期 ([`ecfe88f`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/ecfe88f))
- 为原生验证、渲染器探测和桌面工具编写文档 ([`311ab7a`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/311ab7a))
- 为并发的创意工坊下载排队，并安全接纳已完成的导入 ([`db27a08`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/db27a08))
- 修复渲染器兼容性和渲染目标生命周期的回归 ([`e455b6b`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/e455b6b))
- 发布包含已完成代理更改的完整项目快照 ([`1fb3048`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/1fb3048))
- 发布不包含并发代理工作的初始源码快照 ([`9f33787`](https://github.com/bobbyhuang-dev/WallpaperMachine/commit/9f33787))

**Full changelog**: https://github.com/bobbyhuang-dev/WallpaperMachine/commits/v0.1.0
